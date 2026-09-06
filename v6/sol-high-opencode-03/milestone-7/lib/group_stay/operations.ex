defmodule GroupStay.Operations do
  import Ecto.Query

  alias GroupStay.Credits.{CreditAllocation, CreditEntitlement, CreditLot}
  alias GroupStay.Finance
  alias GroupStay.Funding.AllocationOrder
  alias GroupStay.Operations.Record
  alias GroupStay.Payments.{CashAllocation, CashPayment, CashPaymentDisposition}
  alias GroupStay.Repo
  alias GroupStay.Reservations.{Group, Room}

  @rate_plans ["flexible", "advance_purchase"]
  @new_flexible_policy_on ~D[2027-01-01]

  def submit(operations), do: Enum.map(operations, &process/1)

  def get_operation(operation_id) do
    case Repo.get_by(Record, operation_id: operation_id) do
      nil -> nil
      record -> restore_result(record.result)
    end
  end

  def get_group(group_id) do
    {:ok, result} =
      Repo.transaction(fn ->
        case Repo.get(Group, group_id) do
          nil ->
            nil

          group ->
            rooms = rooms_for_group(group_id)
            serialize_group(group, rooms)
        end
      end)

    result
  end

  def get_payment(operation_id) do
    {:ok, result} =
      Repo.transaction(fn ->
        case Repo.get_by(Record, operation_id: operation_id) do
          nil ->
            {:error, "operation_not_found"}

          record ->
            if applied_cash_record?(record) do
              {:ok, serialize_payment(Repo.get!(CashPayment, operation_id))}
            else
              {:error, "payment_not_reconcilable"}
            end
        end
      end)

    result
  end

  def guest_credit(guest_id, on) do
    lots =
      Repo.all(
        from lot in CreditLot,
          where:
            lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.issued_on <= ^on and
              lot.expires_on >= ^on,
          order_by: [lot.expires_on, lot.source_operation_id, lot.id]
      )

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: lot.expires_on
          }
        end)
    }
  end

  def ledger(on \\ Date.utc_today()) do
    {:ok, totals} =
      Repo.transaction(fn ->
        cash =
          Repo.one(
            from g in Group,
              select: %{
                cash_refunded_cents: fragment("COALESCE(SUM(?), 0)", g.refunded_cents),
                cash_retained_cents: fragment("COALESCE(SUM(?), 0)", g.retained_cents),
                cash_converted_to_credit_cents:
                  fragment("COALESCE(SUM(?), 0)", g.cash_converted_to_credit_cents)
              }
          )

        cash_held =
          Repo.one(
            from a in CashAllocation, select: fragment("COALESCE(SUM(?), 0)", a.amount_cents)
          )

        payment_totals =
          Repo.one(
            from p in CashPayment,
              select: %{
                cash_reduced_cents: fragment("COALESCE(SUM(?), 0)", p.reduced_cents),
                cash_charged_back_cents: fragment("COALESCE(SUM(?), 0)", p.charged_back_cents)
              }
          )

        available_credit =
          Repo.one(
            from lot in CreditLot,
              where: lot.remaining_cents > 0 and lot.issued_on <= ^on and lot.expires_on >= ^on,
              select: fragment("COALESCE(SUM(?), 0)", lot.remaining_cents)
          )

        applied_credit =
          Repo.one(
            from allocation in CreditAllocation,
              join: g in Group,
              on: g.group_id == allocation.group_id,
              join: lot in CreditLot,
              on: lot.id == allocation.credit_lot_id,
              where: g.status == "active" and lot.issued_on <= ^on,
              select: fragment("COALESCE(SUM(?), 0)", allocation.amount_cents)
          )

        credit_shortfall = credit_shortfall()

        cash
        |> Map.put(:cash_held_cents, cash_held)
        |> Map.merge(payment_totals)
        |> Map.put(:credit_liability_cents, available_credit + applied_credit)
        |> Map.put(:credit_shortfall_cents, credit_shortfall)
      end)

    totals
  end

  def reporting_date(nil), do: {:ok, Date.utc_today()}

  def reporting_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, "invalid_date"}
    end
  end

  def reporting_date(_value), do: {:error, "invalid_date"}

  def backfill_room_accounting! do
    allocation_orders_available =
      Repo.query!(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'funding_allocation_orders'"
      ).num_rows == 1

    Process.put(:group_stay_allocation_orders_unavailable, not allocation_orders_available)

    try do
      Repo.all(from group in Group, where: group.accounting_initialized == false)
      |> Enum.each(&ensure_accounting!/1)

      :ok
    after
      Process.delete(:group_stay_allocation_orders_unavailable)
    end
  end

  def backfill_deposit_transfers! do
    record_order =
      Repo.all(from record in Record, select: {record.operation_id, record.id}) |> Map.new()

    Repo.all(from group in Group, order_by: group.group_id, select: group.group_id)
    |> Enum.each(fn group_id ->
      cash =
        Repo.all(
          from allocation in CashAllocation,
            where: allocation.group_id == ^group_id and is_nil(allocation.allocation_order)
        )

      credit =
        Repo.all(
          from allocation in CreditAllocation,
            where: allocation.group_id == ^group_id and is_nil(allocation.allocation_order)
        )

      (Enum.map(cash, &{:cash, &1}) ++ Enum.map(credit, &{:credit, &1}))
      |> Enum.sort_by(&historical_allocation_key(&1, record_order))
      |> Enum.each(fn
        {:cash, allocation} ->
          allocation
          |> CashAllocation.changeset(%{allocation_order: next_allocation_order!()})
          |> Repo.update!()

        {:credit, allocation} ->
          allocation
          |> CreditAllocation.changeset(%{allocation_order: next_allocation_order!()})
          |> Repo.update!()
      end)
    end)

    Repo.all(CashPayment)
    |> Enum.each(fn payment ->
      for field <- [:refunded_cents, :retained_cents, :converted_to_credit_cents],
          amount = Map.fetch!(payment, field),
          amount > 0 do
        %CashPaymentDisposition{}
        |> CashPaymentDisposition.changeset(%{
          payment_operation_id: payment.operation_id,
          group_id: payment.group_id,
          disposition: Atom.to_string(field),
          amount_cents: amount
        })
        |> Repo.insert!()
      end
    end)

    :ok
  end

  defp process(%{"operation_id" => operation_id} = operation)
       when is_binary(operation_id) and operation_id != "" do
    {:ok, result} =
      Repo.transaction(
        fn -> process_idempotently(operation_id, operation) end,
        mode: :immediate
      )

    result
  end

  defp process(operation), do: reject(operation, "invalid_operation")

  defp process_idempotently(operation_id, operation) do
    case Repo.get_by(Record, operation_id: operation_id) do
      nil ->
        result = operation |> dispatch() |> normalize_result()

        %Record{}
        |> Record.changeset(%{
          operation_id: operation_id,
          operation_type: submitted_type(operation),
          submitted_content: operation,
          result: result
        })
        |> Repo.insert!()

        result

      record ->
        if record.submitted_content === operation do
          restore_result(record.result)
        else
          reject(operation, "operation_id_conflict")
        end
    end
  end

  defp dispatch(%{"type" => type} = operation) do
    case type do
      "open_group" -> open_group(operation)
      "record_cash_payment" -> update_group(operation, &record_cash_payment/2)
      "apply_hotel_credit" -> update_group(operation, &apply_hotel_credit/2)
      "reschedule_group" -> update_group(operation, &reschedule_group/2)
      "cancel_group" -> update_group(operation, &cancel_group/2)
      "cancel_rooms" -> update_group(operation, &cancel_rooms/2)
      "reduce_cash_payment" -> reduce_cash_payment(operation)
      "charge_back_payment" -> charge_back_payment(operation)
      "transfer_deposit" -> transfer_deposit(operation)
      "start_finance_reporting" -> Finance.start(operation)
      "close_finance_period" -> Finance.close(operation)
      _ -> reject(operation, "invalid_operation")
    end
  end

  defp dispatch(operation), do: reject(operation, "invalid_operation")

  defp open_group(operation) do
    with {:ok, fields} <- open_fields(operation),
         {:ok, booked_on} <- parse_required_date(fields.occurred_on, "invalid_operation"),
         {:ok, arrival_on} <- parse_required_date(fields.arrival_on, "invalid_stay"),
         {:ok, departure_on} <- parse_required_date(fields.departure_on, "invalid_stay"),
         :ok <- validate_stay(arrival_on, departure_on),
         :ok <- validate_rate_plan(fields.rate_plan),
         {:ok, rooms} <- validate_rooms(fields.rooms) do
      nights = Date.diff(departure_on, arrival_on)

      lodging_total_cents =
        Enum.reduce(rooms, 0, fn room, total ->
          total + room.nightly_rate_cents * nights
        end)

      deposit_due_cents =
        Enum.reduce(rooms, 0, fn room, total ->
          lodging = room.nightly_rate_cents * nights
          total + room_deposit(fields.rate_plan, lodging)
        end)

      attrs = %{
        group_id: fields.group_id,
        guest_id: fields.guest_id,
        property_id: fields.property_id,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: fields.rate_plan,
        policy_version: policy_version(fields.rate_plan, booked_on),
        status: "active",
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        credit_paid_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        cash_converted_to_credit_cents: 0,
        accounting_initialized: true,
        revision: 1
      }

      case insert_group(attrs, rooms) do
        :ok ->
          applied(operation, %{
            group_id: fields.group_id,
            deposit_due_cents: deposit_due_cents,
            revision: 1
          })

        {:error, :group_already_exists} ->
          reject(operation, "group_already_exists")
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp insert_group(attrs, rooms) do
    case Repo.insert(Group.create_changeset(%Group{}, attrs)) do
      {:ok, _group} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        room_rows =
          rooms
          |> Enum.with_index()
          |> Enum.map(fn {room, position} ->
            %{
              group_id: attrs.group_id,
              room_id: room.room_id,
              nightly_rate_cents: room.nightly_rate_cents,
              position: position,
              status: "active",
              lodging_total_cents:
                room.nightly_rate_cents * Date.diff(attrs.departure_on, attrs.arrival_on),
              deposit_due_cents:
                room_deposit(
                  attrs.rate_plan,
                  room.nightly_rate_cents * Date.diff(attrs.departure_on, attrs.arrival_on)
                ),
              inserted_at: now,
              updated_at: now
            }
          end)

        {_count, nil} = Repo.insert_all(Room, room_rows)
        :ok

      {:error, changeset} ->
        if changeset.errors[:group_id] do
          {:error, :group_already_exists}
        else
          raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
        end
    end
  end

  defp update_group(operation, apply_operation) do
    case operation do
      %{"group_id" => group_id} when is_binary(group_id) and group_id != "" ->
        case Repo.get(Group, group_id) do
          nil ->
            reject(operation, "group_not_found")

          group ->
            with :ok <- validate_expected_revision(operation, group),
                 :ok <- validate_active(group) do
              apply_operation.(operation, group)
            else
              {:error, "stale_revision"} -> stale(operation, group)
              {:error, code} -> reject(operation, code)
            end
        end

      _ ->
        reject(operation, "invalid_operation")
    end
  end

  defp record_cash_payment(operation, group) do
    case operation do
      %{"occurred_on" => occurred_on, "amount_cents" => amount_cents} ->
        case parse_required_date(occurred_on, "invalid_operation") do
          {:ok, _occurred_on} ->
            outstanding = group.deposit_due_cents - group.deposit_paid_cents

            cond do
              not (is_integer(amount_cents) and amount_cents > 0) ->
                reject(operation, "invalid_amount")

              amount_cents > outstanding ->
                reject(operation, "payment_exceeds_outstanding")

              true ->
                revision = group.revision + 1
                paid = group.deposit_paid_cents + amount_cents

                %CashPayment{}
                |> CashPayment.changeset(%{
                  operation_id: operation["operation_id"],
                  group_id: group.group_id,
                  recorded_cents: amount_cents
                })
                |> Repo.insert!()

                allocate_cash!(group.group_id, operation["operation_id"], amount_cents)

                group
                |> Group.update_changeset(%{deposit_paid_cents: paid, revision: revision})
                |> Repo.update!()

                Finance.record_cash(
                  operation,
                  group.property_id,
                  "received",
                  amount_cents
                )

                applied(operation, %{
                  group_id: group.group_id,
                  amount_cents: amount_cents,
                  outstanding_deposit_cents: group.deposit_due_cents - paid,
                  revision: revision
                })
            end

          {:error, code} ->
            reject(operation, code)
        end

      _ ->
        reject(operation, "invalid_operation")
    end
  end

  defp apply_hotel_credit(operation, group) do
    case operation do
      %{"occurred_on" => occurred_on, "amount_cents" => amount_cents} ->
        with {:ok, occurred_on} <- parse_required_date(occurred_on, "invalid_operation") do
          outstanding = group.deposit_due_cents - group.deposit_paid_cents

          cond do
            not (is_integer(amount_cents) and amount_cents > 0) ->
              reject(operation, "invalid_amount")

            amount_cents > outstanding ->
              reject(operation, "payment_exceeds_outstanding")

            true ->
              lots = available_credit_lots(group.guest_id, occurred_on)

              if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount_cents do
                reject(operation, "insufficient_credit")
              else
                allocate_credit!(
                  lots,
                  amount_cents,
                  group.group_id,
                  operation["operation_id"]
                )

                Finance.pause_credit(operation, credit_funding_by_lot(operation["operation_id"]))

                revision = group.revision + 1
                paid = group.deposit_paid_cents + amount_cents

                group
                |> Group.update_changeset(%{
                  deposit_paid_cents: paid,
                  credit_paid_cents: group.credit_paid_cents + amount_cents,
                  revision: revision
                })
                |> Repo.update!()

                applied(operation, %{
                  group_id: group.group_id,
                  amount_cents: amount_cents,
                  outstanding_deposit_cents: group.deposit_due_cents - paid,
                  revision: revision
                })
              end
          end
        else
          {:error, code} -> reject(operation, code)
        end

      _ ->
        reject(operation, "invalid_operation")
    end
  end

  defp reschedule_group(operation, group) do
    with %{"occurred_on" => occurred_on, "new_arrival_on" => new_arrival_on} <- operation,
         {:ok, occurred_on} <- parse_required_date(occurred_on, "invalid_stay"),
         {:ok, new_arrival_on} <- parse_required_date(new_arrival_on, "invalid_stay"),
         true <- Date.after?(new_arrival_on, occurred_on) do
      new_departure_on = Date.add(new_arrival_on, Date.diff(group.departure_on, group.arrival_on))
      revision = group.revision + 1

      group
      |> Group.update_changeset(%{
        arrival_on: new_arrival_on,
        departure_on: new_departure_on,
        revision: revision
      })
      |> Repo.update!()

      applied(operation, %{
        group_id: group.group_id,
        new_arrival_on: new_arrival_on,
        new_departure_on: new_departure_on,
        policy_version: group.policy_version,
        refundable_until: refundable_until(group.policy_version, new_arrival_on),
        revision: revision
      })
    else
      {:error, code} -> reject(operation, code)
      false -> reject(operation, "invalid_stay")
      _ -> reject(operation, "invalid_operation")
    end
  end

  defp cancel_group(operation, group) do
    with {:ok, occurred_on, refund_method} <- cancellation_fields(operation) do
      settle_rooms(
        operation,
        group,
        active_rooms(group.group_id),
        occurred_on,
        refund_method,
        false
      )
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp cancel_rooms(operation, group) do
    with {:ok, occurred_on, refund_method} <- cancellation_fields(operation),
         {:ok, rooms} <- selected_active_rooms(group.group_id, operation["room_ids"]) do
      settle_rooms(operation, group, rooms, occurred_on, refund_method, true)
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp cancellation_fields(%{"occurred_on" => value} = operation) do
    with {:ok, occurred_on} <- parse_required_date(value, "invalid_operation"),
         refund_method when refund_method in ["cash", "hotel_credit"] <-
           Map.get(operation, "refund_method", "cash") do
      {:ok, occurred_on, refund_method}
    else
      {:error, code} -> {:error, code}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp cancellation_fields(_operation), do: {:error, "invalid_operation"}

  defp settle_rooms(operation, group, rooms, occurred_on, refund_method, include_rooms) do
    refundable = refundable?(group, occurred_on)

    if refund_method == "hotel_credit" and not refundable do
      reject(operation, "refund_method_not_available")
    else
      room_ids = Enum.map(rooms, & &1.id)

      cash_allocations =
        Repo.all(
          from allocation in CashAllocation,
            where: allocation.room_id in ^room_ids,
            order_by: allocation.id
        )

      cash_paid_cents = Enum.sum(Enum.map(cash_allocations, & &1.amount_cents))

      {refunded_cents, retained_cents, converted_cents, credit_issued_cents} =
        cancellation_amounts(refundable, refund_method, cash_paid_cents)

      settle_cash_allocations!(cash_allocations, group.group_id, refundable, refund_method)
      settle_credit_allocations(room_ids, occurred_on, refundable, operation)

      issued_lot =
        if credit_issued_cents > 0 do
          lot =
            %CreditLot{}
            |> CreditLot.changeset(%{
              guest_id: group.guest_id,
              source_operation_id: operation["operation_id"],
              issued_on: occurred_on,
              expires_on: Date.add(occurred_on, 365),
              remaining_cents: credit_issued_cents
            })
            |> Repo.insert!()

          create_entitlements!(lot, cash_allocations)
          lot
        end

      Enum.each(rooms, fn room ->
        room |> Room.changeset(%{status: "cancelled"}) |> Repo.update!()
      end)

      revision = group.revision + 1
      totals = active_group_totals(group.group_id)

      group
      |> Group.update_changeset(%{
        status: if(totals.active_room_count == 0, do: "cancelled", else: "active"),
        lodging_total_cents: totals.lodging_total_cents,
        deposit_due_cents: totals.deposit_due_cents,
        deposit_paid_cents: totals.deposit_paid_cents,
        credit_paid_cents: totals.credit_paid_cents,
        refunded_cents: group.refunded_cents + refunded_cents,
        retained_cents: group.retained_cents + retained_cents,
        cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted_cents,
        revision: revision
      })
      |> Repo.update!()

      Finance.record_cash(operation, group.property_id, "refunded", refunded_cents)
      Finance.record_cash(operation, group.property_id, "retained", retained_cents)
      Finance.record_cash(operation, group.property_id, "converted_to_credit", converted_cents)

      if issued_lot do
        Finance.issue_credit(operation, issued_lot, credit_issued_cents)
      end

      fields = %{
        group_id: group.group_id,
        refunded_cents: refunded_cents,
        retained_cents: retained_cents,
        credit_issued_cents: credit_issued_cents,
        revision: revision
      }

      fields =
        if include_rooms,
          do: Map.put(fields, :cancelled_room_ids, Enum.map(rooms, & &1.room_id)),
          else: fields

      applied(operation, fields)
    end
  end

  defp available_credit_lots(guest_id, occurred_on) do
    Repo.all(
      from lot in CreditLot,
        where:
          lot.guest_id == ^guest_id and lot.remaining_cents > 0 and
            lot.issued_on <= ^occurred_on and lot.expires_on >= ^occurred_on,
        order_by: [lot.expires_on, lot.source_operation_id, lot.id]
    )
  end

  defp settle_credit_allocations(room_ids, occurred_on, refundable, operation) do
    allocations =
      Repo.all(
        from allocation in CreditAllocation,
          join: lot in CreditLot,
          on: lot.id == allocation.credit_lot_id,
          where: allocation.room_id in ^room_ids,
          preload: [credit_lot: lot]
      )

    allocations
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.each(fn {_lot_id, lot_allocations} ->
      lot = hd(lot_allocations).credit_lot
      amount = Enum.sum(Enum.map(lot_allocations, & &1.amount_cents))

      if refundable do
        absorbed = min(amount, lot.unrecovered_clawback_cents)
        excess = amount - absorbed
        restored = if Date.before?(lot.expires_on, occurred_on), do: 0, else: excess
        expired = excess - restored

        lot
        |> CreditLot.changeset(%{
          unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed,
          remaining_cents: lot.remaining_cents + restored
        })
        |> Repo.update!()

        Finance.record_credit(operation, "absorbed", absorbed)
        Finance.record_credit(operation, "expired", expired)
        Finance.restore_credit(operation, lot, restored)
      else
        Finance.record_credit(operation, "consumed", amount)
      end

      Enum.each(lot_allocations, &Repo.delete!/1)
    end)
  end

  defp cancellation_amounts(true, "cash", cash_paid_cents) do
    {cash_paid_cents, 0, 0, 0}
  end

  defp cancellation_amounts(true, "hotel_credit", cash_paid_cents) do
    credit_issued_cents = cash_paid_cents + percentage(cash_paid_cents, 10)
    {0, 0, cash_paid_cents, credit_issued_cents}
  end

  defp cancellation_amounts(false, "cash", cash_paid_cents) do
    {0, cash_paid_cents, 0, 0}
  end

  defp transfer_deposit(operation) do
    with {:ok, source_group_id, destination_group_id} <- transfer_group_ids(operation),
         {:ok, source} <- transfer_group(source_group_id),
         {:ok, destination} <- transfer_group(destination_group_id),
         :ok <- transfer_revision(operation, source, "expected_revision"),
         :ok <- transfer_revision(operation, destination, "destination_expected_revision"),
         :ok <- Finance.validate_operation_date(operation),
         {:ok, amount} <- validate_transfer(operation, source, destination) do
      destination_plan = allocation_plan(destination.group_id, amount)
      chunks = draw_transferred_funding!(source.group_id, amount)
      allocate_transferred_funding!(chunks, destination_plan)
      mark_transferred_payments!(chunks)

      source = update_group_accounting!(source, source.revision + 1)
      destination = update_group_accounting!(destination, destination.revision + 1)

      transferred_cash =
        chunks
        |> Enum.filter(&(&1.kind == :cash))
        |> Enum.map(& &1.amount_cents)
        |> Enum.sum()

      Finance.record_cash(operation, source.property_id, "transferred_out", transferred_cash)

      Finance.record_cash(
        operation,
        destination.property_id,
        "transferred_in",
        transferred_cash
      )

      applied(operation, %{
        source_group_id: source.group_id,
        destination_group_id: destination.group_id,
        amount_cents: amount,
        source_outstanding_deposit_cents: source.deposit_due_cents - source.deposit_paid_cents,
        destination_outstanding_deposit_cents:
          destination.deposit_due_cents - destination.deposit_paid_cents,
        source_revision: source.revision,
        destination_revision: destination.revision
      })
    else
      {:missing_group, group_id} ->
        reject(operation, "group_not_found", %{group_id: group_id})

      {:stale, group, revision_field} ->
        stale(operation, group, revision_field)

      {:inactive_group, group} ->
        reject(operation, "group_not_active", %{group_id: group.group_id})

      {:error, code} ->
        reject(operation, code)
    end
  end

  defp transfer_group_ids(operation) do
    case operation do
      %{"source_group_id" => source_group_id, "destination_group_id" => destination_group_id}
      when is_binary(source_group_id) and source_group_id != "" and
             is_binary(destination_group_id) and destination_group_id != "" ->
        {:ok, source_group_id, destination_group_id}

      _ ->
        {:error, "invalid_operation"}
    end
  end

  defp transfer_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:missing_group, group_id}
      group -> {:ok, group}
    end
  end

  defp transfer_revision(operation, group, field) do
    case Map.fetch(operation, field) do
      :error ->
        :ok

      {:ok, expected} when is_integer(expected) and expected > 0 ->
        if expected == group.revision, do: :ok, else: {:stale, group, field}

      {:ok, _expected} ->
        {:error, "invalid_operation"}
    end
  end

  defp validate_transfer(operation, source, destination) do
    cond do
      source.group_id == destination.group_id or source.guest_id != destination.guest_id ->
        {:error, "invalid_transfer"}

      source.status != "active" ->
        {:inactive_group, source}

      destination.status != "active" ->
        {:inactive_group, destination}

      not Map.has_key?(operation, "amount_cents") ->
        {:error, "invalid_operation"}

      not (is_integer(operation["amount_cents"]) and operation["amount_cents"] > 0) ->
        {:error, "invalid_amount"}

      operation["amount_cents"] > group_held_funding(source.group_id) ->
        {:error, "transfer_exceeds_held_funding"}

      operation["amount_cents"] >
          destination.deposit_due_cents - destination.deposit_paid_cents ->
        {:error, "transfer_exceeds_outstanding"}

      true ->
        {:ok, operation["amount_cents"]}
    end
  end

  defp draw_transferred_funding!(group_id, amount) do
    cash =
      Repo.all(from allocation in CashAllocation, where: allocation.group_id == ^group_id)
      |> Enum.map(&%{kind: :cash, allocation: &1})

    credit =
      Repo.all(from allocation in CreditAllocation, where: allocation.group_id == ^group_id)
      |> Enum.map(&%{kind: :credit, allocation: &1})

    {chunks, remaining} =
      (cash ++ credit)
      |> Enum.sort_by(& &1.allocation.allocation_order, :desc)
      |> Enum.reduce_while({[], amount}, fn item, {chunks, remaining} ->
        if remaining == 0 do
          {:halt, {chunks, 0}}
        else
          moved = min(item.allocation.amount_cents, remaining)
          reduce_transferred_allocation!(item, moved)

          chunk =
            item
            |> Map.take([:kind])
            |> Map.merge(transfer_provenance(item))
            |> Map.put(:amount_cents, moved)

          {:cont, {[chunk | chunks], remaining - moved}}
        end
      end)

    if remaining != 0, do: raise("funding allocation underflow")
    Enum.reverse(chunks)
  end

  defp reduce_transferred_allocation!(%{allocation: allocation}, moved)
       when moved == allocation.amount_cents do
    Repo.delete!(allocation)
  end

  defp reduce_transferred_allocation!(%{kind: :cash, allocation: allocation}, moved) do
    allocation
    |> CashAllocation.changeset(%{amount_cents: allocation.amount_cents - moved})
    |> Repo.update!()
  end

  defp reduce_transferred_allocation!(%{kind: :credit, allocation: allocation}, moved) do
    allocation
    |> CreditAllocation.changeset(%{amount_cents: allocation.amount_cents - moved})
    |> Repo.update!()
  end

  defp transfer_provenance(%{kind: :cash, allocation: allocation}) do
    %{payment_operation_id: allocation.payment_operation_id}
  end

  defp transfer_provenance(%{kind: :credit, allocation: allocation}) do
    %{
      credit_lot_id: allocation.credit_lot_id,
      funding_operation_id: allocation.funding_operation_id
    }
  end

  defp allocate_transferred_funding!(chunks, plan) do
    transfer_chunks_into_rooms(chunks, plan)
    :ok
  end

  defp transfer_chunks_into_rooms([], []), do: :ok

  defp transfer_chunks_into_rooms(
         [%{amount_cents: chunk_amount} = chunk | chunks],
         [{room, room_amount} | rooms]
       ) do
    moved = min(chunk_amount, room_amount)
    insert_transferred_allocation!(chunk, room, moved)

    next_chunks =
      if moved == chunk_amount,
        do: chunks,
        else: [%{chunk | amount_cents: chunk_amount - moved} | chunks]

    next_rooms =
      if moved == room_amount,
        do: rooms,
        else: [{room, room_amount - moved} | rooms]

    transfer_chunks_into_rooms(next_chunks, next_rooms)
  end

  defp insert_transferred_allocation!(%{kind: :cash} = chunk, room, amount) do
    %CashAllocation{}
    |> CashAllocation.changeset(%{
      group_id: room.group_id,
      room_id: room.id,
      payment_operation_id: chunk.payment_operation_id,
      amount_cents: amount,
      allocation_order: next_allocation_order!()
    })
    |> Repo.insert!()
  end

  defp insert_transferred_allocation!(%{kind: :credit} = chunk, room, amount) do
    %CreditAllocation{}
    |> CreditAllocation.changeset(%{
      group_id: room.group_id,
      room_id: room.id,
      credit_lot_id: chunk.credit_lot_id,
      funding_operation_id: chunk.funding_operation_id,
      amount_cents: amount,
      allocation_order: next_allocation_order!()
    })
    |> Repo.insert!()
  end

  defp mark_transferred_payments!(chunks) do
    chunks
    |> Enum.filter(&(&1.kind == :cash and not is_nil(&1.payment_operation_id)))
    |> Enum.map(& &1.payment_operation_id)
    |> Enum.uniq()
    |> Enum.each(fn operation_id ->
      operation_id
      |> then(&Repo.get!(CashPayment, &1))
      |> CashPayment.changeset(%{transfer_participated: true})
      |> Repo.update!()
    end)
  end

  defp reduce_cash_payment(operation) do
    with {:ok, record, payment, group} <- reducible_payment(operation),
         :ok <- revision_or_stale(operation, group),
         :ok <- Finance.validate_operation_date(operation),
         %{"amount_cents" => amount} <- operation,
         true <- (is_integer(amount) and amount > 0) || {:error, "invalid_amount"} do
      held = payment_held_cents(payment.operation_id)

      cond do
        held == 0 ->
          reject(operation, "payment_not_reducible")

        amount > held ->
          reject(operation, "reduction_exceeds_held_cash")

        true ->
          affected_groups = remove_cash_allocations!(payment.operation_id, amount)

          payment
          |> CashPayment.changeset(%{reduced_cents: payment.reduced_cents + amount})
          |> Repo.update!()

          updated_groups = increment_changed_groups!([group.group_id | Map.keys(affected_groups)])
          updated = Map.fetch!(updated_groups, group.group_id)

          Enum.each(affected_groups, fn {group_id, reduced} ->
            property_id = Repo.get!(Group, group_id).property_id
            Finance.record_cash(operation, property_id, "reduced", reduced)
          end)

          applied(operation, %{
            payment_operation_id: record.operation_id,
            group_id: group.group_id,
            amount_cents: amount,
            outstanding_deposit_cents: updated.deposit_due_cents - updated.deposit_paid_cents,
            revision: updated.revision
          })
      end
    else
      {:stale, group} -> stale(operation, group)
      {:error, code} -> reject(operation, code)
      _ -> reject(operation, "invalid_operation")
    end
  end

  defp charge_back_payment(operation) do
    with {:ok, record, payment, group} <- payment_target(operation),
         :ok <- revision_or_stale(operation, group),
         :ok <- Finance.validate_operation_date(operation) do
      if payment.charged_back_cents > 0 or payment.reduced_cents == payment.recorded_cents do
        reject(operation, "payment_not_chargeable")
      else
        held = payment_held_cents(payment.operation_id)
        charged_back = payment.recorded_cents - payment.reduced_cents

        held_groups =
          if held > 0, do: remove_cash_allocations!(payment.operation_id, held), else: %{}

        revoke_credit_entitlements!(operation, payment.operation_id)

        dispositions =
          Repo.all(
            from disposition in CashPaymentDisposition,
              where: disposition.payment_operation_id == ^payment.operation_id
          )

        payment
        |> CashPayment.changeset(%{
          refunded_cents: 0,
          retained_cents: 0,
          converted_to_credit_cents: 0,
          charged_back_cents: charged_back
        })
        |> Repo.update!()

        disposition_group_ids = reverse_payment_dispositions!(dispositions)
        Enum.each(dispositions, &Repo.delete!/1)

        Enum.each(held_groups, fn {group_id, amount} ->
          property_id = Repo.get!(Group, group_id).property_id
          Finance.record_cash(operation, property_id, "charged_back", amount)
        end)

        Enum.each(dispositions, fn disposition ->
          property_id = Repo.get!(Group, disposition.group_id).property_id
          kind = finance_disposition_kind(disposition.disposition)
          Finance.record_cash(operation, property_id, kind, -disposition.amount_cents)
          Finance.record_cash(operation, property_id, "charged_back", disposition.amount_cents)
        end)

        updated_groups =
          increment_changed_groups!([
            group.group_id | Map.keys(held_groups) ++ disposition_group_ids
          ])

        group = Map.fetch!(updated_groups, group.group_id)

        applied(operation, %{
          payment_operation_id: record.operation_id,
          group_id: group.group_id,
          charged_back_cents: charged_back,
          outstanding_deposit_cents: group.deposit_due_cents - group.deposit_paid_cents,
          revision: group.revision
        })
      end
    else
      {:stale, group} -> stale(operation, group)
      {:error, "payment_not_reconcilable"} -> reject(operation, "payment_not_chargeable")
      {:error, code} -> reject(operation, code)
    end
  end

  defp reducible_payment(operation) do
    with {:ok, record, payment, group} <- payment_target(operation) do
      {:ok, record, payment, group}
    else
      {:error, "payment_not_reconcilable"} -> {:error, "payment_not_reducible"}
      error -> error
    end
  end

  defp payment_target(%{"payment_operation_id" => operation_id})
       when is_binary(operation_id) and operation_id != "" do
    case Repo.get_by(Record, operation_id: operation_id) do
      nil ->
        {:error, "operation_not_found"}

      record ->
        if applied_cash_record?(record) do
          group = Repo.get!(Group, result_value(record.result, "group_id"))

          {:ok, record, Repo.get!(CashPayment, operation_id), group}
        else
          {:error, "payment_not_reconcilable"}
        end
    end
  end

  defp payment_target(_operation), do: {:error, "invalid_operation"}

  defp revision_or_stale(operation, group) do
    case validate_expected_revision(operation, group) do
      :ok -> :ok
      {:error, "stale_revision"} -> {:stale, group}
      error -> error
    end
  end

  defp allocate_cash!(group_id, payment_operation_id, amount) do
    group_id
    |> allocation_plan(amount)
    |> Enum.each(fn {room, room_amount} ->
      %CashAllocation{}
      |> CashAllocation.changeset(%{
        group_id: group_id,
        room_id: room.id,
        payment_operation_id: payment_operation_id,
        amount_cents: room_amount,
        allocation_order: next_allocation_order!()
      })
      |> Repo.insert!()
    end)
  end

  defp allocate_credit!(lots, amount, group_id, operation_id) do
    group_id
    |> allocation_plan(amount)
    |> Enum.reduce(lots, fn {room, room_amount}, remaining_lots ->
      consume_lots_for_room!(remaining_lots, room_amount, group_id, room.id, operation_id)
    end)

    :ok
  end

  defp consume_lots_for_room!([lot | rest], amount, group_id, room_id, operation_id) do
    consumed = min(lot.remaining_cents, amount)

    updated_lot =
      lot
      |> CreditLot.changeset(%{remaining_cents: lot.remaining_cents - consumed})
      |> Repo.update!()

    %CreditAllocation{}
    |> CreditAllocation.changeset(%{
      group_id: group_id,
      credit_lot_id: lot.id,
      room_id: room_id,
      funding_operation_id: operation_id,
      amount_cents: consumed,
      allocation_order: next_allocation_order!()
    })
    |> Repo.insert!()

    cond do
      consumed == amount and updated_lot.remaining_cents == 0 -> rest
      consumed == amount -> [updated_lot | rest]
      true -> consume_lots_for_room!(rest, amount - consumed, group_id, room_id, operation_id)
    end
  end

  defp allocation_plan(group_id, amount) do
    {plan, remaining} =
      group_id
      |> active_rooms()
      |> Enum.reduce_while({[], amount}, fn room, {plan, remaining} ->
        if remaining == 0 do
          {:halt, {plan, 0}}
        else
          room_outstanding = room.deposit_due_cents - room_paid_cents(room.id)
          allocated = min(room_outstanding, remaining)
          plan = if allocated > 0, do: [{room, allocated} | plan], else: plan
          {:cont, {plan, remaining - allocated}}
        end
      end)

    if remaining != 0, do: raise("funding exceeds active room deposits")
    Enum.reverse(plan)
  end

  defp settle_cash_allocations!(allocations, group_id, refundable, refund_method) do
    disposition =
      case {refundable, refund_method} do
        {true, "cash"} -> :refunded_cents
        {true, "hotel_credit"} -> :converted_to_credit_cents
        {false, "cash"} -> :retained_cents
      end

    allocations
    |> Enum.reject(&is_nil(&1.payment_operation_id))
    |> Enum.group_by(& &1.payment_operation_id)
    |> Enum.each(fn {operation_id, payment_allocations} ->
      payment = Repo.get!(CashPayment, operation_id)
      amount = Enum.sum(Enum.map(payment_allocations, & &1.amount_cents))

      payment
      |> CashPayment.changeset(%{disposition => Map.fetch!(payment, disposition) + amount})
      |> Repo.update!()

      %CashPaymentDisposition{}
      |> CashPaymentDisposition.changeset(%{
        payment_operation_id: operation_id,
        group_id: group_id,
        disposition: Atom.to_string(disposition),
        amount_cents: amount
      })
      |> Repo.insert!()
    end)

    Enum.each(allocations, &Repo.delete!/1)
  end

  defp create_entitlements!(lot, allocations) do
    contributors =
      allocations
      |> Enum.group_by(& &1.payment_operation_id)
      |> Enum.map(fn {payment_operation_id, items} ->
        %{
          payment_operation_id: payment_operation_id,
          principal_cents: Enum.sum(Enum.map(items, & &1.amount_cents)),
          first_allocation_order: Enum.min(Enum.map(items, & &1.allocation_order))
        }
      end)
      |> Enum.sort_by(fn contributor ->
        {if(is_nil(contributor.payment_operation_id), do: 0, else: 1),
         contributor.first_allocation_order}
      end)

    {_principal, entitlement_total} =
      Enum.reduce(contributors, {0, 0}, fn contributor, {principal, entitlement_total} ->
        next_principal = principal + contributor.principal_cents
        next_total = next_principal + percentage(next_principal, 10)
        entitlement = next_total - entitlement_total

        %CreditEntitlement{}
        |> CreditEntitlement.changeset(%{
          credit_lot_id: lot.id,
          payment_operation_id: contributor.payment_operation_id,
          principal_cents: contributor.principal_cents,
          entitlement_cents: entitlement
        })
        |> Repo.insert!()

        {next_principal, next_total}
      end)

    if entitlement_total != lot.remaining_cents, do: raise("credit entitlements do not telescope")
  end

  defp remove_cash_allocations!(payment_operation_id, amount) do
    allocations =
      Repo.all(
        from allocation in CashAllocation,
          where: allocation.payment_operation_id == ^payment_operation_id,
          order_by: [desc: allocation.allocation_order]
      )

    {remaining, amounts_by_group} =
      Enum.reduce_while(allocations, {amount, %{}}, fn allocation,
                                                       {remaining, amounts_by_group} ->
        cond do
          remaining == 0 ->
            {:halt, {0, amounts_by_group}}

          remaining >= allocation.amount_cents ->
            amounts_by_group =
              Map.update(
                amounts_by_group,
                allocation.group_id,
                allocation.amount_cents,
                &(&1 + allocation.amount_cents)
              )

            Repo.delete!(allocation)
            {:cont, {remaining - allocation.amount_cents, amounts_by_group}}

          true ->
            amounts_by_group =
              Map.update(amounts_by_group, allocation.group_id, remaining, &(&1 + remaining))

            allocation
            |> CashAllocation.changeset(%{amount_cents: allocation.amount_cents - remaining})
            |> Repo.update!()

            {:halt, {0, amounts_by_group}}
        end
      end)

    if remaining != 0, do: raise("cash allocation underflow")
    amounts_by_group
  end

  defp reverse_payment_dispositions!(dispositions) do
    dispositions
    |> Enum.group_by(& &1.group_id)
    |> Enum.map(fn {group_id, group_dispositions} ->
      changes =
        Enum.reduce(group_dispositions, %{}, fn disposition, changes ->
          field = group_disposition_field(disposition.disposition)
          Map.update(changes, field, disposition.amount_cents, &(&1 + disposition.amount_cents))
        end)

      group = Repo.get!(Group, group_id)

      changes =
        Map.new(changes, fn {field, amount} ->
          {field, Map.fetch!(group, field) - amount}
        end)

      group |> Group.update_changeset(changes) |> Repo.update!()
      group_id
    end)
  end

  defp group_disposition_field("refunded_cents"), do: :refunded_cents
  defp group_disposition_field("retained_cents"), do: :retained_cents

  defp group_disposition_field("converted_to_credit_cents"),
    do: :cash_converted_to_credit_cents

  defp finance_disposition_kind("refunded_cents"), do: "refunded"
  defp finance_disposition_kind("retained_cents"), do: "retained"
  defp finance_disposition_kind("converted_to_credit_cents"), do: "converted_to_credit"

  defp increment_changed_groups!(group_ids) do
    group_ids
    |> Enum.uniq()
    |> Map.new(fn group_id ->
      group = Repo.get!(Group, group_id)
      updated = update_group_accounting!(group, group.revision + 1)
      {group_id, updated}
    end)
  end

  defp revoke_credit_entitlements!(operation, payment_operation_id) do
    Repo.all(
      from entitlement in CreditEntitlement,
        where: entitlement.payment_operation_id == ^payment_operation_id,
        order_by: entitlement.id
    )
    |> Enum.each(fn entitlement ->
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      revoked = min(lot.remaining_cents, entitlement.entitlement_cents)

      lot
      |> CreditLot.changeset(%{
        remaining_cents: lot.remaining_cents - revoked,
        unrecovered_clawback_cents:
          lot.unrecovered_clawback_cents + entitlement.entitlement_cents - revoked
      })
      |> Repo.update!()

      Finance.revoke_credit(operation, lot.id, revoked)
    end)
  end

  defp policy_version("flexible", booked_on) do
    if Date.before?(booked_on, @new_flexible_policy_on), do: "flex-14", else: "flex-30"
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp refundable_until("flex-14", arrival_on), do: Date.add(arrival_on, -14)
  defp refundable_until("flex-30", arrival_on), do: Date.add(arrival_on, -30)
  defp refundable_until("advance-nonrefundable", _arrival_on), do: nil

  defp refundable?(group, occurred_on) do
    case refundable_until(group.policy_version, group.arrival_on) do
      nil -> false
      cutoff -> not Date.after?(occurred_on, cutoff)
    end
  end

  defp open_fields(operation) do
    required = [
      "occurred_on",
      "group_id",
      "guest_id",
      "property_id",
      "arrival_on",
      "departure_on",
      "rate_plan",
      "rooms"
    ]

    if Enum.all?(required, &Map.has_key?(operation, &1)) and
         valid_identifier?(operation["group_id"]) and
         valid_identifier?(operation["guest_id"]) and
         valid_identifier?(operation["property_id"]) do
      {:ok,
       %{
         occurred_on: operation["occurred_on"],
         group_id: operation["group_id"],
         guest_id: operation["guest_id"],
         property_id: operation["property_id"],
         arrival_on: operation["arrival_on"],
         departure_on: operation["departure_on"],
         rate_plan: operation["rate_plan"],
         rooms: operation["rooms"]
       }}
    else
      {:error, "invalid_operation"}
    end
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    parsed =
      Enum.map(rooms, fn
        %{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents}
        when is_binary(room_id) and room_id != "" and is_integer(nightly_rate_cents) and
               nightly_rate_cents > 0 ->
          %{room_id: room_id, nightly_rate_cents: nightly_rate_cents}

        _ ->
          :invalid
      end)

    room_ids = Enum.map(parsed, &if(is_map(&1), do: &1.room_id, else: nil))

    if :invalid in parsed or length(Enum.uniq(room_ids)) != length(room_ids) do
      {:error, "invalid_rooms"}
    else
      {:ok, parsed}
    end
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp validate_stay(arrival_on, departure_on) do
    if Date.before?(arrival_on, departure_on), do: :ok, else: {:error, "invalid_stay"}
  end

  defp validate_rate_plan(rate_plan) do
    if rate_plan in @rate_plans, do: :ok, else: {:error, "invalid_rate_plan"}
  end

  defp validate_active(%Group{status: "active"}), do: :ok
  defp validate_active(_group), do: {:error, "group_not_active"}

  defp validate_expected_revision(operation, group) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, expected} when is_integer(expected) and expected > 0 ->
        if expected == group.revision, do: :ok, else: {:error, "stale_revision"}

      {:ok, _expected} ->
        {:error, "invalid_operation"}
    end
  end

  defp parse_required_date(value, error_code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, error_code}
    end
  end

  defp parse_required_date(_value, error_code), do: {:error, error_code}

  defp room_deposit("flexible", lodging_cents), do: percentage(lodging_cents, 20)
  defp room_deposit("advance_purchase", lodging_cents), do: lodging_cents

  defp percentage(cents, percent), do: div(cents * percent + 50, 100)

  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp rooms_for_group(group_id) do
    Repo.all(from room in Room, where: room.group_id == ^group_id, order_by: room.position)
  end

  defp active_rooms(group_id) do
    Repo.all(
      from room in Room,
        where: room.group_id == ^group_id and room.status == "active",
        order_by: room.position
    )
  end

  defp selected_active_rooms(group_id, room_ids)
       when is_list(room_ids) and room_ids != [] do
    if Enum.all?(room_ids, &valid_identifier?/1) and
         length(Enum.uniq(room_ids)) == length(room_ids) do
      selected =
        Repo.all(
          from room in Room,
            where:
              room.group_id == ^group_id and room.status == "active" and
                room.room_id in ^room_ids,
            order_by: room.position
        )

      if length(selected) == length(room_ids),
        do: {:ok, selected},
        else: {:error, "invalid_rooms"}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp selected_active_rooms(_group_id, _room_ids), do: {:error, "invalid_rooms"}

  defp room_paid_cents(room_id) do
    cash =
      Repo.one(
        from allocation in CashAllocation,
          where: allocation.room_id == ^room_id,
          select: fragment("COALESCE(SUM(?), 0)", allocation.amount_cents)
      )

    credit =
      Repo.one(
        from allocation in CreditAllocation,
          where: allocation.room_id == ^room_id,
          select: fragment("COALESCE(SUM(?), 0)", allocation.amount_cents)
      )

    cash + credit
  end

  defp group_held_funding(group_id) do
    cash =
      Repo.one(
        from allocation in CashAllocation,
          where: allocation.group_id == ^group_id,
          select: fragment("COALESCE(SUM(?), 0)", allocation.amount_cents)
      )

    credit =
      Repo.one(
        from allocation in CreditAllocation,
          where: allocation.group_id == ^group_id,
          select: fragment("COALESCE(SUM(?), 0)", allocation.amount_cents)
      )

    cash + credit
  end

  defp room_balances(room_ids) do
    cash =
      Repo.all(
        from allocation in CashAllocation,
          where: allocation.room_id in ^room_ids,
          group_by: allocation.room_id,
          select: {allocation.room_id, sum(allocation.amount_cents)}
      )
      |> Map.new()

    credit =
      Repo.all(
        from allocation in CreditAllocation,
          where: allocation.room_id in ^room_ids,
          group_by: allocation.room_id,
          select: {allocation.room_id, sum(allocation.amount_cents)}
      )
      |> Map.new()

    {cash, credit}
  end

  defp active_group_totals(group_id) do
    rooms = active_rooms(group_id)
    {cash, credit} = room_balances(Enum.map(rooms, & &1.id))
    cash_paid = Enum.sum(Enum.map(rooms, &Map.get(cash, &1.id, 0)))
    credit_paid = Enum.sum(Enum.map(rooms, &Map.get(credit, &1.id, 0)))

    %{
      active_room_count: length(rooms),
      lodging_total_cents: Enum.sum(Enum.map(rooms, & &1.lodging_total_cents)),
      deposit_due_cents: Enum.sum(Enum.map(rooms, & &1.deposit_due_cents)),
      deposit_paid_cents: cash_paid + credit_paid,
      credit_paid_cents: credit_paid
    }
  end

  defp update_group_accounting!(group, revision) do
    totals = active_group_totals(group.group_id)

    group
    |> Group.update_changeset(%{
      lodging_total_cents: totals.lodging_total_cents,
      deposit_due_cents: totals.deposit_due_cents,
      deposit_paid_cents: totals.deposit_paid_cents,
      credit_paid_cents: totals.credit_paid_cents,
      revision: revision
    })
    |> Repo.update!()
  end

  defp payment_held_cents(operation_id) do
    Repo.one(
      from allocation in CashAllocation,
        where: allocation.payment_operation_id == ^operation_id,
        select: fragment("COALESCE(SUM(?), 0)", allocation.amount_cents)
    )
  end

  defp credit_funding_by_lot(operation_id) do
    Repo.all(
      from allocation in CreditAllocation,
        where: allocation.funding_operation_id == ^operation_id,
        group_by: allocation.credit_lot_id,
        select: {allocation.credit_lot_id, sum(allocation.amount_cents)}
    )
  end

  defp serialize_payment(payment) do
    statement = %{
      payment_operation_id: payment.operation_id,
      original_group_id: payment.group_id,
      recorded_cents: payment.recorded_cents,
      held_cents: payment_held_cents(payment.operation_id),
      refunded_cents: payment.refunded_cents,
      retained_cents: payment.retained_cents,
      converted_to_credit_cents: payment.converted_to_credit_cents,
      reduced_cents: payment.reduced_cents,
      charged_back_cents: payment.charged_back_cents
    }

    if payment.transfer_participated do
      Map.put(statement, :held_by_group, payment_held_by_group(payment.operation_id))
    else
      statement
    end
  end

  defp payment_held_by_group(operation_id) do
    Repo.all(
      from allocation in CashAllocation,
        where: allocation.payment_operation_id == ^operation_id,
        group_by: allocation.group_id,
        order_by: allocation.group_id,
        select: %{
          group_id: allocation.group_id,
          amount_cents: sum(allocation.amount_cents)
        }
    )
  end

  defp applied_cash_record?(record) do
    record.operation_type == "record_cash_payment" and
      result_value(record.result, "status") == "applied"
  end

  defp result_value(map, key), do: Map.get(map, key) || Map.get(map, String.to_existing_atom(key))

  defp credit_shortfall do
    Repo.all(CreditLot)
    |> Enum.reduce(0, fn lot, total ->
      applied =
        Repo.one(
          from allocation in CreditAllocation,
            where: allocation.credit_lot_id == ^lot.id,
            select: fragment("COALESCE(SUM(?), 0)", allocation.amount_cents)
        )

      total + min(lot.unrecovered_clawback_cents, applied)
    end)
  end

  defp ensure_accounting!(%Group{accounting_initialized: true} = group), do: group

  defp ensure_accounting!(group) do
    records =
      Repo.all(from record in Record, order_by: record.id)
      |> Enum.filter(fn record ->
        result_value(record.result, "group_id") == group.group_id and
          result_value(record.result, "status") == "applied"
      end)

    payment_records = Enum.filter(records, &(&1.operation_type == "record_cash_payment"))
    credit_records = Enum.filter(records, &(&1.operation_type == "apply_hotel_credit"))
    create_legacy_payment_accounts!(group, payment_records)

    if group.status == "active" do
      reconstruct_active_allocations!(group, records, payment_records, credit_records)
    else
      reconstruct_cancelled_entitlements!(group, records, payment_records)
    end

    group
    |> Group.update_changeset(%{accounting_initialized: true})
    |> Repo.update!()
    |> update_group_accounting!(group.revision)
  end

  defp create_legacy_payment_accounts!(group, records) do
    cash_total =
      if group.status == "active" do
        group.deposit_paid_cents - group.credit_paid_cents
      else
        group.refunded_cents + group.retained_cents + group.cash_converted_to_credit_cents
      end

    durable_total = Enum.sum(Enum.map(records, &result_value(&1.result, "amount_cents")))
    legacy_total = max(cash_total - durable_total, 0)

    dispositions = [
      {:refunded_cents, group.refunded_cents},
      {:retained_cents, group.retained_cents},
      {:converted_to_credit_cents, group.cash_converted_to_credit_cents}
    ]

    {_legacy, remaining_dispositions} = consume_dispositions(dispositions, legacy_total)

    Enum.reduce(records, remaining_dispositions, fn record, available ->
      amount = result_value(record.result, "amount_cents")
      {attrs, available} = payment_dispositions(available, amount, group.status)

      payment_attrs =
        Map.merge(attrs, %{
          operation_id: record.operation_id,
          group_id: group.group_id,
          recorded_cents: amount
        })

      if Process.get(:group_stay_allocation_orders_unavailable) do
        now = DateTime.utc_now()

        Repo.insert_all(
          "cash_payments",
          [Map.merge(payment_attrs, %{inserted_at: now, updated_at: now})],
          on_conflict: :nothing
        )
      else
        %CashPayment{}
        |> CashPayment.changeset(payment_attrs)
        |> Repo.insert!(on_conflict: :nothing)
      end

      available
    end)
  end

  defp payment_dispositions(dispositions, _amount, "active"), do: {%{}, dispositions}

  defp payment_dispositions(dispositions, amount, _status) do
    {used, remaining} = consume_dispositions(dispositions, amount)
    {Map.new(used), remaining}
  end

  defp consume_dispositions(dispositions, amount) do
    {used, remaining, _amount} =
      Enum.reduce(dispositions, {[], [], amount}, fn {field, available},
                                                     {used, remaining, left} ->
        taken = min(available, left)
        {[{field, taken} | used], [{field, available - taken} | remaining], left - taken}
      end)

    {Enum.reverse(used), Enum.reverse(remaining)}
  end

  defp reconstruct_active_allocations!(group, records, payment_records, credit_records) do
    old_credit =
      Repo.all(
        from allocation in CreditAllocation,
          where: allocation.group_id == ^group.group_id,
          order_by: allocation.id,
          select: %{
            id: allocation.id,
            credit_lot_id: allocation.credit_lot_id,
            amount_cents: allocation.amount_cents
          }
      )

    Repo.delete_all(
      from allocation in CreditAllocation, where: allocation.group_id == ^group.group_id
    )

    durable_cash =
      Enum.sum(Enum.map(payment_records, &result_value(&1.result, "amount_cents")))

    durable_credit =
      Enum.sum(Enum.map(credit_records, &result_value(&1.result, "amount_cents")))

    legacy_cash = group.deposit_paid_cents - group.credit_paid_cents - durable_cash
    legacy_credit = group.credit_paid_cents - durable_credit

    if legacy_cash > 0, do: allocate_cash!(group.group_id, nil, legacy_cash)

    {credit_chunks, remaining_credit} =
      allocate_existing_credit!(old_credit, legacy_credit, group.group_id, nil)

    {_chunks, _remaining_credit} =
      Enum.reduce(records, {credit_chunks, remaining_credit}, fn record, {chunks, _remaining} ->
        amount = result_value(record.result, "amount_cents")

        case record.operation_type do
          "record_cash_payment" ->
            allocate_cash!(group.group_id, record.operation_id, amount)
            {chunks, 0}

          "apply_hotel_credit" ->
            allocate_existing_credit!(chunks, amount, group.group_id, record.operation_id)

          _ ->
            {chunks, 0}
        end
      end)
  end

  defp allocate_existing_credit!(chunks, 0, _group_id, _operation_id), do: {chunks, 0}

  defp allocate_existing_credit!(chunks, amount, group_id, operation_id) do
    room_plan = allocation_plan(group_id, amount)

    {chunks, remaining} =
      Enum.reduce(room_plan, {chunks, amount}, fn {room, room_amount}, {chunks, remaining} ->
        {chunks, room_remaining} =
          consume_existing_chunks!(chunks, room_amount, group_id, room.id, operation_id)

        {chunks, remaining - (room_amount - room_remaining)}
      end)

    {chunks, remaining}
  end

  defp consume_existing_chunks!([allocation | rest], amount, group_id, room_id, operation_id) do
    consumed = min(allocation.amount_cents, amount)

    %CreditAllocation{}
    |> CreditAllocation.changeset(%{
      group_id: group_id,
      credit_lot_id: allocation.credit_lot_id,
      room_id: room_id,
      funding_operation_id: operation_id,
      amount_cents: consumed,
      allocation_order: next_allocation_order!()
    })
    |> Repo.insert!()

    cond do
      consumed == amount and consumed == allocation.amount_cents ->
        {rest, 0}

      consumed == amount ->
        {[%{allocation | amount_cents: allocation.amount_cents - consumed} | rest], 0}

      true ->
        consume_existing_chunks!(rest, amount - consumed, group_id, room_id, operation_id)
    end
  end

  defp reconstruct_cancelled_entitlements!(group, records, payment_records) do
    if group.cash_converted_to_credit_cents > 0 do
      cancellation_ids =
        records
        |> Enum.filter(&(&1.operation_type in ["cancel_group", "cancel_rooms"]))
        |> Enum.map(& &1.operation_id)

      case Repo.one(from lot in CreditLot, where: lot.source_operation_id in ^cancellation_ids) do
        nil ->
          :ok

        lot ->
          durable =
            Enum.map(payment_records, fn record ->
              payment = Repo.get!(CashPayment, record.operation_id)
              {record.operation_id, payment.converted_to_credit_cents}
            end)
            |> Enum.filter(fn {_id, amount} -> amount > 0 end)

          legacy =
            group.cash_converted_to_credit_cents - Enum.sum(Enum.map(durable, &elem(&1, 1)))

          contributors = if legacy > 0, do: [{nil, legacy} | durable], else: durable
          create_historical_entitlements!(lot, contributors)
      end
    end
  end

  defp create_historical_entitlements!(lot, contributors) do
    Enum.reduce(contributors, {0, 0}, fn {payment_id, amount}, {principal, total} ->
      next_principal = principal + amount
      next_total = next_principal + percentage(next_principal, 10)

      %CreditEntitlement{}
      |> CreditEntitlement.changeset(%{
        credit_lot_id: lot.id,
        payment_operation_id: payment_id,
        principal_cents: amount,
        entitlement_cents: next_total - total
      })
      |> Repo.insert!()

      {next_principal, next_total}
    end)
  end

  defp historical_allocation_key({:cash, allocation}, record_order) do
    if is_nil(allocation.payment_operation_id) do
      {0, 0, allocation.id}
    else
      {2, Map.get(record_order, allocation.payment_operation_id, 9_223_372_036_854_775_807),
       allocation.id}
    end
  end

  defp historical_allocation_key({:credit, allocation}, record_order) do
    if is_nil(allocation.funding_operation_id) do
      {1, 0, allocation.id}
    else
      {2, Map.get(record_order, allocation.funding_operation_id, 9_223_372_036_854_775_807),
       allocation.id}
    end
  end

  defp next_allocation_order! do
    unless Process.get(:group_stay_allocation_orders_unavailable) do
      %AllocationOrder{} |> Repo.insert!() |> Map.fetch!(:id)
    end
  end

  defp submitted_type(%{"type" => type}) when is_binary(type), do: type
  defp submitted_type(%{"type" => type}), do: Jason.encode!(type)
  defp submitted_type(_operation), do: nil

  defp normalize_result(result) do
    result
    |> Jason.encode!()
    |> Jason.decode!()
    |> restore_result()
  end

  defp restore_result(result) do
    Map.new(result, fn
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
      pair -> pair
    end)
  end

  defp serialize_group(group, rooms) do
    {cash, credit} = room_balances(Enum.map(rooms, & &1.id))

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: group.booked_on,
      arrival_on: group.arrival_on,
      departure_on: group.departure_on,
      rate_plan: group.rate_plan,
      policy_version: group.policy_version,
      refundable_until: refundable_until(group.policy_version, group.arrival_on),
      status: group.status,
      rooms:
        Enum.map(rooms, fn room ->
          %{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            status: room.status,
            lodging_total_cents: room.lodging_total_cents,
            deposit_due_cents: room.deposit_due_cents,
            cash_paid_cents: Map.get(cash, room.id, 0),
            credit_paid_cents: Map.get(credit, room.id, 0)
          }
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.deposit_paid_cents - group.credit_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents:
        if(group.status == "active",
          do: group.deposit_due_cents - group.deposit_paid_cents,
          else: 0
        )
    }
  end

  defp applied(operation, fields) do
    Map.merge(
      %{operation_id: operation["operation_id"], status: "applied"},
      fields
    )
  end

  defp reject(operation, code, fields \\ %{}) do
    operation_id = if is_map(operation), do: operation["operation_id"], else: nil

    Map.merge(
      %{operation_id: operation_id, status: "rejected", code: code},
      fields
    )
  end

  defp stale(operation, group), do: stale(operation, group, "expected_revision")

  defp stale(operation, group, revision_field) do
    reject(operation, "stale_revision", %{
      group_id: group.group_id,
      expected_revision: operation[revision_field],
      actual_revision: group.revision
    })
  end
end
