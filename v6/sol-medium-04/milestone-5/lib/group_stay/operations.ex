defmodule GroupStay.Operations do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.{
    CashAllocation,
    CashDisposition,
    CreditApplication,
    CreditEntitlement,
    CreditLot,
    Group,
    OperationRecord,
    PaymentAccount,
    Repo,
    Room
  }

  @rate_plans ~w(flexible advance_purchase)
  @group_operation_fields %{
    "record_cash_payment" => ["operation_id", "type", "occurred_on", "group_id", "amount_cents"],
    "apply_hotel_credit" => ["operation_id", "type", "occurred_on", "group_id", "amount_cents"],
    "reschedule_group" => ["operation_id", "type", "occurred_on", "group_id", "new_arrival_on"],
    "cancel_group" => ["operation_id", "type", "occurred_on", "group_id"],
    "cancel_rooms" => ["operation_id", "type", "occurred_on", "group_id", "room_ids"]
  }

  def process_batch(operations) do
    Enum.map(operations, &process/1)
  end

  def get_group(id) when is_binary(id) do
    case Repo.get(Group, id) do
      nil ->
        nil

      group ->
        ensure_room_accounting!(group)

        Repo.preload(group, [rooms: [:cash_allocations, :credit_applications]], force: true)
    end
  end

  def get_group(_), do: nil

  def get_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> nil
      record -> record.result
    end
  end

  def get_operation(_), do: nil

  def get_payment(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil ->
        {:error, :not_found}

      record ->
        case payment_account_for_record(record) do
          nil ->
            {:error, :not_reconcilable}

          account ->
            group = Repo.get!(Group, account.group_id)
            ensure_room_accounting!(group)
            account = Repo.get!(PaymentAccount, account.id)

            held =
              Repo.one(
                from a in CashAllocation,
                  where: a.payment_account_id == ^account.id,
                  select: coalesce(sum(a.amount_cents), 0)
              )

            statement = %{
              payment_operation_id: account.operation_id,
              original_group_id: account.group_id,
              recorded_cents: account.recorded_cents,
              held_cents: held,
              refunded_cents: account.refunded_cents,
              retained_cents: account.retained_cents,
              converted_to_credit_cents: account.converted_cents,
              reduced_cents: account.reduced_cents,
              charged_back_cents: account.charged_back_cents
            }

            statement =
              if account.participated_in_transfer do
                held_by_group =
                  Repo.all(
                    from a in CashAllocation,
                      where: a.payment_account_id == ^account.id,
                      group_by: a.group_id,
                      order_by: a.group_id,
                      select: %{
                        group_id: a.group_id,
                        amount_cents: coalesce(sum(a.amount_cents), 0)
                      }
                  )

                Map.put(statement, :held_by_group, held_by_group)
              else
                statement
              end

            {:ok, statement}
        end
    end
  end

  def get_payment(_), do: {:error, :not_found}

  def ledger(on \\ Date.utc_today()) do
    Repo.all(from g in Group, where: g.status == "active")
    |> Enum.each(&ensure_room_accounting!/1)

    cash =
      Repo.one(
        from g in Group,
          select: %{
            cash_refunded_cents: coalesce(sum(g.cash_refunded_cents), 0),
            cash_retained_cents: coalesce(sum(g.cash_retained_cents), 0),
            cash_converted_to_credit_cents: coalesce(sum(g.cash_converted_to_credit_cents), 0)
          }
      )

    held = Repo.one(from a in CashAllocation, select: coalesce(sum(a.amount_cents), 0))
    reduced = Repo.one(from p in PaymentAccount, select: coalesce(sum(p.reduced_cents), 0))
    charged = Repo.one(from p in PaymentAccount, select: coalesce(sum(p.charged_back_cents), 0))

    available =
      Repo.one(
        from l in CreditLot,
          where: l.remaining_cents > 0 and l.expires_on > ^on,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    applied =
      Repo.one(
        from a in CreditApplication,
          join: g in assoc(a, :group),
          where: g.status == "active",
          select: coalesce(sum(a.amount_cents), 0)
      )

    shortfall = credit_shortfall()

    cash
    |> Map.put(:cash_held_cents, held)
    |> Map.put(:cash_reduced_cents, reduced)
    |> Map.put(:cash_charged_back_cents, charged)
    |> Map.put(:credit_liability_cents, available + applied)
    |> Map.put(:credit_shortfall_cents, shortfall)
  end

  def guest_credit(guest_id, on \\ Date.utc_today()) do
    lots =
      Repo.all(
        from l in CreditLot,
          where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on > ^on,
          order_by: [asc: l.expires_on, asc: l.source_operation_id]
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

  def read_date(nil), do: {:ok, Date.utc_today()}

  def read_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  def read_date(_), do: :error

  def refundable_until(group) do
    case group.policy_version || policy_version(group.rate_plan, group.booked_on) do
      "flex-14" -> Date.add(group.arrival_on, -14)
      "flex-30" -> Date.add(group.arrival_on, -30)
      "advance-nonrefundable" -> nil
    end
  end

  defp process(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")

    if is_binary(operation_id) do
      {:ok, result} =
        Repo.transaction(fn -> process_durable(operation_id, operation) end, mode: :immediate)

      result
    else
      format_result(operation_id, process_new(operation))
    end
  end

  defp process(_), do: format_result(nil, {:rejected, "invalid_operation", %{}})

  defp process_durable(operation_id, operation) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil ->
        result = format_result(operation_id, process_new(operation))

        record =
          Repo.insert!(%OperationRecord{
            operation_id: operation_id,
            operation_type: if(is_binary(operation["type"]), do: operation["type"]),
            submission: operation,
            result: result
          })

        if operation["type"] == "record_cash_payment" and result[:status] == "applied" do
          case Repo.get_by(PaymentAccount, operation_id: operation_id) do
            nil -> :ok
            account -> update_payment!(account, %{operation_record_id: record.id})
          end
        end

        result

      %OperationRecord{submission: stored, result: result} when stored === operation ->
        result

      %OperationRecord{} ->
        format_result(operation_id, {:rejected, "operation_id_conflict", %{}})
    end
  end

  defp process_new(operation) do
    case Map.get(operation, "type") do
      "open_group" -> open_group(operation)
      "reduce_cash_payment" -> apply_to_payment("reduce_cash_payment", operation)
      "charge_back_payment" -> apply_to_payment("charge_back_payment", operation)
      "transfer_deposit" -> transfer_deposit(operation)
      type when is_map_key(@group_operation_fields, type) -> apply_to_group(type, operation)
      _ -> {:rejected, "invalid_operation", %{}}
    end
  end

  defp open_group(operation) do
    required =
      ~w(operation_id type occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms)

    with :ok <- require_fields(operation, required),
         :ok <-
           require_nonempty_strings(operation, ~w(operation_id group_id guest_id property_id)),
         {:ok, booked_on} <- parse_date(operation["occurred_on"], "invalid_operation"),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"], "invalid_stay"),
         {:ok, departure_on} <- parse_date(operation["departure_on"], "invalid_stay"),
         :ok <- valid_stay(arrival_on, departure_on),
         {:ok, rooms} <- validate_rooms(operation["rooms"]),
         {:ok, rate_plan} <- validate_rate_plan(operation["rate_plan"]) do
      nights = Date.diff(departure_on, arrival_on)

      rooms =
        Enum.map(rooms, fn room ->
          lodging = room.nightly_rate_cents * nights
          due = if rate_plan == "flexible", do: round_percent(lodging, 20), else: lodging

          Map.merge(room, %{
            lodging_total_cents: lodging,
            deposit_due_cents: due,
            status: "active"
          })
        end)

      lodging_total = Enum.sum(Enum.map(rooms, & &1.lodging_total_cents))
      deposit_due = Enum.sum(Enum.map(rooms, & &1.deposit_due_cents))

      attrs = %{
        id: operation["group_id"],
        guest_id: operation["guest_id"],
        property_id: operation["property_id"],
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        policy_version: policy_version(rate_plan, booked_on),
        status: "active",
        lodging_total_cents: lodging_total,
        deposit_due_cents: deposit_due,
        revision: 1
      }

      case insert_group(attrs, rooms) do
        group_id when is_binary(group_id) ->
          {:applied, %{group_id: attrs.id, deposit_due_cents: deposit_due, revision: 1}}

        :already_exists ->
          {:rejected, "group_already_exists", %{}}
      end
    else
      {:error, code} -> {:rejected, code, %{}}
    end
  end

  defp insert_group(attrs, rooms) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    group_row =
      Map.merge(attrs, %{
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        cash_refunded_cents: 0,
        cash_retained_cents: 0,
        cash_converted_to_credit_cents: 0,
        inserted_at: now,
        updated_at: now
      })

    case Repo.insert_all(Group, [group_row], on_conflict: :nothing, conflict_target: [:id]) do
      {1, nil} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        room_rows =
          rooms
          |> Enum.with_index()
          |> Enum.map(fn {room, position} ->
            Map.merge(room, %{
              group_id: attrs.id,
              position: position,
              inserted_at: now,
              updated_at: now
            })
          end)

        {_count, nil} = Repo.insert_all(Room, room_rows)
        attrs.id

      {0, nil} ->
        :already_exists
    end
  end

  defp apply_to_group(type, operation) do
    required = Map.fetch!(@group_operation_fields, type)

    with :ok <- require_fields(operation, required),
         :ok <- require_nonempty_strings(operation, ~w(operation_id group_id)) do
      apply_locked(type, operation)
    else
      {:error, code} -> {:rejected, code, %{}}
    end
  end

  defp transfer_deposit(operation) do
    required =
      ~w(operation_id type occurred_on source_group_id destination_group_id amount_cents)

    with :ok <- require_fields(operation, required),
         :ok <-
           require_nonempty_strings(
             operation,
             ~w(operation_id source_group_id destination_group_id)
           ),
         {:ok, _occurred_on} <- parse_date(operation["occurred_on"], "invalid_operation") do
      apply_transfer(operation)
    else
      {:error, code} -> {:rejected, code, %{}}
    end
  end

  defp apply_transfer(operation) do
    source = Repo.get(Group, operation["source_group_id"])

    if is_nil(source) do
      {:rejected, "group_not_found", %{group_id: operation["source_group_id"]}}
    else
      destination = Repo.get(Group, operation["destination_group_id"])

      cond do
        is_nil(destination) ->
          {:rejected, "group_not_found", %{group_id: operation["destination_group_id"]}}

        stale_revision?(operation, source) ->
          stale_result(source, operation["expected_revision"])

        invalid_expected_revision?(operation) ->
          {:rejected, "invalid_operation", %{}}

        stale_revision?(operation, destination, "destination_expected_revision") ->
          stale_result(destination, operation["destination_expected_revision"])

        invalid_expected_revision?(operation, "destination_expected_revision") ->
          {:rejected, "invalid_operation", %{}}

        source.id == destination.id or source.guest_id != destination.guest_id ->
          {:rejected, "invalid_transfer", %{}}

        source.status != "active" ->
          {:rejected, "group_not_active", %{group_id: source.id}}

        destination.status != "active" ->
          {:rejected, "group_not_active", %{group_id: destination.id}}

        not is_integer(operation["amount_cents"]) or operation["amount_cents"] <= 0 ->
          {:rejected, "invalid_amount", %{}}

        true ->
          ensure_room_accounting!(source)
          ensure_room_accounting!(destination)
          perform_transfer(operation, source, destination)
      end
    end
  end

  defp perform_transfer(operation, source, destination) do
    amount = operation["amount_cents"]
    source_held = source.deposit_paid_cents
    destination_outstanding = destination.deposit_due_cents - destination.deposit_paid_cents

    cond do
      amount > source_held ->
        {:rejected, "transfer_exceeds_held_funding", %{}}

      amount > destination_outstanding ->
        {:rejected, "transfer_exceeds_outstanding", %{}}

      true ->
        chunks = draw_transfer_chunks!(source.id, amount)

        Enum.each(chunks, fn
          {:cash, account_id, chunk_amount} ->
            account = if account_id, do: Repo.get!(PaymentAccount, account_id)

            if account,
              do: update_payment!(account, %{participated_in_transfer: true})

            allocate_cash!(destination, account, chunk_amount)

          {:credit, lot_id, operation_id, chunk_amount} ->
            allocate_credit_chunk!(destination, lot_id, operation_id, chunk_amount)
        end)

        source_revision = source.revision + 1
        destination_revision = destination.revision + 1

        source = sync_group_totals!(source, %{revision: source_revision})
        destination = sync_group_totals!(destination, %{revision: destination_revision})

        {:applied,
         %{
           source_group_id: source.id,
           destination_group_id: destination.id,
           amount_cents: amount,
           source_outstanding_deposit_cents: source.deposit_due_cents - source.deposit_paid_cents,
           destination_outstanding_deposit_cents:
             destination.deposit_due_cents - destination.deposit_paid_cents,
           source_revision: source_revision,
           destination_revision: destination_revision
         }}
    end
  end

  defp draw_transfer_chunks!(source_group_id, amount) do
    cash =
      Repo.all(
        from a in CashAllocation,
          where: a.group_id == ^source_group_id,
          select: {:cash, a.id, a.allocation_order, a.payment_account_id, a.amount_cents}
      )

    credit =
      Repo.all(
        from a in CreditApplication,
          where: a.group_id == ^source_group_id,
          select:
            {:credit, a.id, a.allocation_order, a.credit_lot_id, a.funding_operation_id,
             a.amount_cents}
      )

    allocations = Enum.sort_by(cash ++ credit, &elem(&1, 2), :desc)

    {chunks, left} =
      Enum.reduce_while(allocations, {[], amount}, fn allocation, {chunks, left} ->
        if left == 0 do
          {:halt, {chunks, 0}}
        else
          available = elem(allocation, tuple_size(allocation) - 1)
          drawn = min(available, left)
          reduce_transfer_allocation!(allocation, drawn)

          chunk =
            case allocation do
              {:cash, _id, _order, account_id, _amount} ->
                {:cash, account_id, drawn}

              {:credit, _id, _order, lot_id, operation_id, _amount} ->
                {:credit, lot_id, operation_id, drawn}
            end

          {:cont, {[chunk | chunks], left - drawn}}
        end
      end)

    if left != 0, do: raise("transfer allocation underflow")
    Enum.reverse(chunks)
  end

  defp reduce_transfer_allocation!({:cash, id, _order, _account_id, available}, drawn) do
    allocation = Repo.get!(CashAllocation, id)
    reduce_or_delete_allocation!(allocation, available, drawn)
  end

  defp reduce_transfer_allocation!(
         {:credit, id, _order, _lot_id, _operation_id, available},
         drawn
       ) do
    application = Repo.get!(CreditApplication, id)
    reduce_or_delete_allocation!(application, available, drawn)
  end

  defp reduce_or_delete_allocation!(allocation, available, drawn) do
    if drawn == available do
      Repo.delete!(allocation)
    else
      allocation
      |> Ecto.Changeset.change(amount_cents: available - drawn)
      |> Repo.update!()
    end
  end

  defp apply_locked(type, operation) do
    group = Repo.one(from g in Group, where: g.id == ^operation["group_id"])

    cond do
      is_nil(group) ->
        {:rejected, "group_not_found", %{}}

      stale_revision?(operation, group) ->
        {:rejected, "stale_revision",
         %{
           group_id: group.id,
           expected_revision: operation["expected_revision"],
           actual_revision: group.revision
         }}

      invalid_expected_revision?(operation) ->
        {:rejected, "invalid_operation", %{}}

      group.status != "active" ->
        {:rejected, "group_not_active", %{}}

      true ->
        ensure_room_accounting!(group)
        perform(type, operation, group)
    end
  end

  defp perform("record_cash_payment", operation, group) do
    amount = operation["amount_cents"]
    outstanding = group.deposit_due_cents - group.deposit_paid_cents

    cond do
      match?({:error, _}, parse_date(operation["occurred_on"], "invalid_operation")) ->
        {:rejected, "invalid_operation", %{}}

      not is_integer(amount) or amount <= 0 ->
        {:rejected, "invalid_amount", %{}}

      amount > outstanding ->
        {:rejected, "payment_exceeds_outstanding", %{}}

      true ->
        account =
          Repo.insert!(%PaymentAccount{
            operation_id: operation["operation_id"],
            group_id: group.id,
            recorded_cents: amount
          })

        allocate_cash!(group, account, amount)
        revision = group.revision + 1
        sync_group_totals!(group, %{revision: revision})

        {:applied,
         %{
           group_id: group.id,
           amount_cents: amount,
           outstanding_deposit_cents: outstanding - amount,
           revision: revision
         }}
    end
  end

  defp perform("reschedule_group", operation, group) do
    with {:ok, occurred_on} <- parse_date(operation["occurred_on"], "invalid_stay"),
         {:ok, new_arrival} <- parse_date(operation["new_arrival_on"], "invalid_stay"),
         true <- Date.compare(new_arrival, occurred_on) == :gt do
      shift = Date.diff(new_arrival, group.arrival_on)
      new_departure = Date.add(group.departure_on, shift)
      revision = group.revision + 1

      update_group!(group, %{
        arrival_on: new_arrival,
        departure_on: new_departure,
        revision: revision
      })

      {:applied,
       %{
         group_id: group.id,
         new_arrival_on: new_arrival,
         new_departure_on: new_departure,
         policy_version: group.policy_version || policy_version(group.rate_plan, group.booked_on),
         refundable_until: refundable_until(%{group | arrival_on: new_arrival}),
         revision: revision
       }}
    else
      _ -> {:rejected, "invalid_stay", %{}}
    end
  end

  defp perform("cancel_group", operation, group) do
    rooms = active_rooms(group.id)

    perform_cancellation(operation, group, rooms, false)
  end

  defp perform("cancel_rooms", operation, group) do
    room_ids = operation["room_ids"]

    rooms =
      if is_list(room_ids) do
        Repo.all(
          from r in Room,
            where: r.group_id == ^group.id and r.room_id in ^room_ids,
            order_by: r.position
        )
      else
        []
      end

    valid =
      is_list(room_ids) and room_ids != [] and Enum.all?(room_ids, &is_binary/1) and
        Enum.uniq(room_ids) == room_ids and length(rooms) == length(room_ids) and
        Enum.all?(rooms, &(&1.status == "active"))

    if valid do
      perform_cancellation(operation, group, rooms, true)
    else
      {:rejected, "invalid_rooms", %{}}
    end
  end

  defp perform("apply_hotel_credit", operation, group),
    do: apply_hotel_credit(operation, group)

  defp perform_cancellation(operation, group, rooms, partial?) do
    case parse_date(operation["occurred_on"], "invalid_operation") do
      {:ok, occurred_on} ->
        refund_method = Map.get(operation, "refund_method", "cash")
        refundable = refundable?(group, occurred_on)

        cond do
          refund_method not in ["cash", "hotel_credit"] ->
            {:rejected, "invalid_operation", %{}}

          refund_method == "hotel_credit" and not refundable ->
            {:rejected, "refund_method_not_available", %{}}

          true ->
            settle_rooms(
              group,
              rooms,
              operation,
              occurred_on,
              refundable,
              refund_method,
              partial?
            )
        end

      {:error, _code} ->
        {:rejected, "invalid_operation", %{}}
    end
  end

  defp apply_hotel_credit(operation, group) do
    amount = operation["amount_cents"]
    outstanding = group.deposit_due_cents - group.deposit_paid_cents

    with {:ok, occurred_on} <- parse_date(operation["occurred_on"], "invalid_operation") do
      cond do
        not is_integer(amount) or amount <= 0 ->
          {:rejected, "invalid_amount", %{}}

        amount > outstanding ->
          {:rejected, "payment_exceeds_outstanding", %{}}

        true ->
          lots =
            Repo.all(
              from l in CreditLot,
                where:
                  l.guest_id == ^group.guest_id and l.remaining_cents > 0 and
                    l.expires_on > ^occurred_on,
                order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
            )

          if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
            {:rejected, "insufficient_credit", %{}}
          else
            consume_credit_lots!(lots, group, operation["operation_id"], amount)
            revision = group.revision + 1
            sync_group_totals!(group, %{revision: revision})

            {:applied,
             %{
               group_id: group.id,
               amount_cents: amount,
               outstanding_deposit_cents: outstanding - amount,
               revision: revision
             }}
          end
      end
    else
      _ -> {:rejected, "invalid_operation", %{}}
    end
  end

  defp settle_rooms(group, rooms, operation, occurred_on, refundable, refund_method, partial?) do
    room_db_ids = Enum.map(rooms, & &1.id)

    cash_allocations =
      Repo.all(
        from a in CashAllocation,
          where: a.room_id in ^room_db_ids,
          order_by: [asc: a.allocation_order, asc: a.id]
      )

    applications =
      Repo.all(
        from a in CreditApplication,
          where: a.room_id in ^room_db_ids,
          order_by: [asc: a.allocation_order, asc: a.id]
      )

    if refundable do
      Enum.each(applications, &restore_credit!(&1, occurred_on))
    else
      Enum.each(applications, &Repo.delete!/1)
    end

    cash_cents = Enum.sum(Enum.map(cash_allocations, & &1.amount_cents))
    refunded = if refundable and refund_method == "cash", do: cash_cents, else: 0
    retained = if refundable, do: 0, else: cash_cents

    credit_issued =
      if refundable and refund_method == "hotel_credit" do
        issue_credit!(
          group.guest_id,
          operation["operation_id"],
          cash_allocations,
          occurred_on
        )
      else
        0
      end

    disposition =
      cond do
        retained > 0 -> :retained_cents
        refunded > 0 -> :refunded_cents
        credit_issued > 0 -> :converted_cents
        true -> nil
      end

    if disposition do
      cash_allocations
      |> Enum.reject(&is_nil(&1.payment_account_id))
      |> Enum.group_by(& &1.payment_account_id)
      |> Enum.each(fn {account_id, allocations} ->
        account = Repo.get!(PaymentAccount, account_id)
        amount = Enum.sum(Enum.map(allocations, & &1.amount_cents))
        update_payment!(account, %{disposition => Map.fetch!(account, disposition) + amount})

        Repo.insert!(%CashDisposition{
          payment_account_id: account_id,
          group_id: group.id,
          kind: disposition_kind(disposition),
          amount_cents: amount
        })
      end)
    end

    Enum.each(cash_allocations, &Repo.delete!/1)
    Enum.each(rooms, &update_room!(&1, %{status: "cancelled"}))

    converted = if credit_issued > 0, do: cash_cents, else: 0
    revision = group.revision + 1
    status = if active_rooms(group.id) == [], do: "cancelled", else: "active"

    sync_group_totals!(group, %{
      status: status,
      cash_refunded_cents: group.cash_refunded_cents + refunded,
      cash_retained_cents: group.cash_retained_cents + retained,
      cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted,
      revision: revision
    })

    result = %{
      group_id: group.id,
      refunded_cents: refunded,
      retained_cents: retained,
      credit_issued_cents: credit_issued,
      revision: revision
    }

    result =
      if partial?,
        do: Map.put(result, :cancelled_room_ids, Enum.map(rooms, & &1.room_id)),
        else: result

    {:applied, result}
  end

  defp consume_credit_lots!(_lots, _group, _operation_id, 0), do: :ok

  defp consume_credit_lots!([lot | rest], group, operation_id, amount) do
    used = min(lot.remaining_cents, amount)
    update_credit_lot!(lot, %{remaining_cents: lot.remaining_cents - used})
    allocate_credit_chunk!(group, lot.id, operation_id, used)
    consume_credit_lots!(rest, group, operation_id, amount - used)
  end

  defp restore_credit!(application, occurred_on) do
    # A lot may fund the same group through more than one operation, so reload it before
    # restoring each allocation rather than overwriting a restoration with stale state.
    lot = Repo.get!(CreditLot, application.credit_lot_id)

    absorbed = min(lot.unrecovered_clawback_cents, application.amount_cents)
    restored = application.amount_cents - absorbed

    attrs = %{unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed}

    attrs =
      if restored > 0 and Date.compare(lot.expires_on, occurred_on) == :gt,
        do: Map.put(attrs, :remaining_cents, lot.remaining_cents + restored),
        else: attrs

    update_credit_lot!(lot, attrs)

    Repo.delete!(application)
  end

  defp issue_credit!(_guest_id, _operation_id, [], _occurred_on), do: 0

  defp issue_credit!(guest_id, operation_id, cash_allocations, occurred_on) do
    cash_cents = Enum.sum(Enum.map(cash_allocations, & &1.amount_cents))
    amount = cash_cents + round_percent(cash_cents, 10)

    lot =
      Repo.insert!(%CreditLot{
        guest_id: guest_id,
        source_operation_id: operation_id,
        remaining_cents: amount,
        expires_on: Date.add(occurred_on, 366)
      })

    add_entitlements!(lot, cash_allocations)

    amount
  end

  defp apply_to_payment(type, operation) do
    required =
      if type == "reduce_cash_payment",
        do: ~w(operation_id type occurred_on payment_operation_id amount_cents),
        else: ~w(operation_id type occurred_on payment_operation_id)

    with :ok <- require_fields(operation, required),
         :ok <- require_nonempty_strings(operation, ~w(operation_id payment_operation_id)) do
      case Repo.get_by(OperationRecord, operation_id: operation["payment_operation_id"]) do
        nil ->
          {:rejected, "operation_not_found", %{}}

        record ->
          case payment_account_for_record(record) do
            nil ->
              code =
                if type == "reduce_cash_payment",
                  do: "payment_not_reducible",
                  else: "payment_not_chargeable"

              {:rejected, code, %{}}

            account ->
              group = Repo.get!(Group, account.group_id)
              ensure_room_accounting!(group)
              account = Repo.get!(PaymentAccount, account.id)

              cond do
                stale_revision?(operation, group) ->
                  {:rejected, "stale_revision",
                   %{
                     group_id: group.id,
                     expected_revision: operation["expected_revision"],
                     actual_revision: group.revision
                   }}

                invalid_expected_revision?(operation) ->
                  {:rejected, "invalid_operation", %{}}

                match?(
                  {:error, _},
                  parse_date(operation["occurred_on"], "invalid_operation")
                ) ->
                  {:rejected, "invalid_operation", %{}}

                type == "reduce_cash_payment" ->
                  reduce_payment(operation, group, account)

                true ->
                  charge_back_payment(operation, group, account)
              end
          end
      end
    else
      {:error, code} -> {:rejected, code, %{}}
    end
  end

  defp reduce_payment(operation, group, account) do
    amount = operation["amount_cents"]
    held = held_for_payment(account.id)

    cond do
      not is_integer(amount) or amount <= 0 ->
        {:rejected, "invalid_amount", %{}}

      held == 0 ->
        {:rejected, "payment_not_reducible", %{}}

      amount > held ->
        {:rejected, "reduction_exceeds_held_cash", %{}}

      true ->
        changed_group_ids = remove_cash_allocations!(account.id, amount)
        update_payment!(account, %{reduced_cents: account.reduced_cents + amount})
        updated_groups = increment_changed_groups!(group.id, changed_group_ids)
        updated = Map.fetch!(updated_groups, group.id)

        {:applied,
         %{
           payment_operation_id: account.operation_id,
           group_id: group.id,
           amount_cents: amount,
           outstanding_deposit_cents: updated.deposit_due_cents - updated.deposit_paid_cents,
           revision: updated.revision
         }}
    end
  end

  defp charge_back_payment(_operation, group, account) do
    chargeable = account.recorded_cents - account.reduced_cents

    if chargeable <= 0 or account.charged_back_cents > 0 do
      {:rejected, "payment_not_chargeable", %{}}
    else
      held = held_for_payment(account.id)
      held_group_ids = remove_cash_allocations!(account.id, held)

      dispositions =
        Repo.all(from d in CashDisposition, where: d.payment_account_id == ^account.id)

      disposition_groups =
        dispositions
        |> Enum.group_by(& &1.group_id)
        |> Map.new(fn {group_id, entries} ->
          totals =
            Enum.reduce(entries, %{refunded: 0, retained: 0, converted: 0}, fn entry, acc ->
              Map.update!(acc, String.to_existing_atom(entry.kind), &(&1 + entry.amount_cents))
            end)

          {group_id, totals}
        end)

      Enum.each(dispositions, &Repo.delete!/1)

      Repo.all(from e in CreditEntitlement, where: e.payment_account_id == ^account.id)
      |> Enum.each(&claw_back_entitlement!/1)

      update_payment!(account, %{
        refunded_cents: 0,
        retained_cents: 0,
        converted_cents: 0,
        charged_back_cents: chargeable
      })

      changed_group_ids = Enum.uniq(held_group_ids ++ Map.keys(disposition_groups))

      updated_groups =
        increment_changed_groups!(group.id, changed_group_ids, fn changed_group ->
          totals =
            Map.get(disposition_groups, changed_group.id, %{
              refunded: 0,
              retained: 0,
              converted: 0
            })

          %{
            cash_refunded_cents: changed_group.cash_refunded_cents - totals.refunded,
            cash_retained_cents: changed_group.cash_retained_cents - totals.retained,
            cash_converted_to_credit_cents:
              changed_group.cash_converted_to_credit_cents - totals.converted
          }
        end)

      updated = Map.fetch!(updated_groups, group.id)

      {:applied,
       %{
         payment_operation_id: account.operation_id,
         group_id: group.id,
         charged_back_cents: chargeable,
         outstanding_deposit_cents: updated.deposit_due_cents - updated.deposit_paid_cents,
         revision: updated.revision
       }}
    end
  end

  defp claw_back_entitlement!(entitlement) do
    lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
    revoked = min(lot.remaining_cents, entitlement.amount_cents)

    update_credit_lot!(lot, %{
      remaining_cents: lot.remaining_cents - revoked,
      unrecovered_clawback_cents:
        lot.unrecovered_clawback_cents + entitlement.amount_cents - revoked
    })
  end

  defp add_entitlements!(lot, cash_allocations) do
    contributions =
      cash_allocations
      |> Enum.chunk_by(& &1.payment_account_id)
      |> Enum.map(fn allocations ->
        {hd(allocations).payment_account_id, Enum.sum(Enum.map(allocations, & &1.amount_cents))}
      end)

    Enum.reduce(contributions, 0, fn {account_id, cash}, running ->
      before = running + round_percent(running, 10)
      after_cash = running + cash
      after_value = after_cash + round_percent(after_cash, 10)
      entitlement = after_value - before

      if account_id do
        case Repo.get_by(CreditEntitlement,
               credit_lot_id: lot.id,
               payment_account_id: account_id
             ) do
          nil ->
            Repo.insert!(%CreditEntitlement{
              credit_lot_id: lot.id,
              payment_account_id: account_id,
              amount_cents: entitlement
            })

          existing ->
            existing
            |> Ecto.Changeset.change(amount_cents: existing.amount_cents + entitlement)
            |> Repo.update!()
        end
      end

      after_cash
    end)
  end

  defp allocate_cash!(group, account, amount) do
    allocate_to_rooms!(group, amount, fn room, used ->
      Repo.insert!(%CashAllocation{
        group_id: group.id,
        room_id: room.id,
        payment_account_id: account && account.id,
        amount_cents: used,
        allocation_order: next_allocation_order()
      })
    end)
  end

  defp allocate_credit_chunk!(group, lot_id, operation_id, amount) do
    allocate_to_rooms!(group, amount, fn room, used ->
      Repo.insert!(%CreditApplication{
        group_id: group.id,
        room_id: room.id,
        credit_lot_id: lot_id,
        funding_operation_id: operation_id,
        amount_cents: used,
        allocation_order: next_allocation_order()
      })
    end)
  end

  defp allocate_to_rooms!(group, amount, insert) do
    rooms = active_rooms(group.id)

    remaining =
      Enum.reduce(rooms, amount, fn room, left ->
        if left == 0 do
          0
        else
          paid = room_paid(room.id)
          used = min(left, room.deposit_due_cents - paid)
          if used > 0, do: insert.(room, used)
          left - used
        end
      end)

    if remaining != 0, do: raise("funding allocation exceeded active room requirement")
    :ok
  end

  defp remove_cash_allocations!(_account_id, 0), do: []

  defp remove_cash_allocations!(account_id, amount) do
    allocations =
      Repo.all(
        from a in CashAllocation,
          where: a.payment_account_id == ^account_id,
          order_by: [desc: a.allocation_order, desc: a.id]
      )

    {left, group_ids} =
      Enum.reduce_while(allocations, {amount, []}, fn allocation, {left, group_ids} ->
        group_ids = [allocation.group_id | group_ids]

        cond do
          left == 0 ->
            {:halt, {0, group_ids}}

          allocation.amount_cents < left ->
            Repo.delete!(allocation)
            {:cont, {left - allocation.amount_cents, group_ids}}

          allocation.amount_cents == left ->
            Repo.delete!(allocation)
            {:halt, {0, group_ids}}

          true ->
            allocation
            |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - left)
            |> Repo.update!()

            {:halt, {0, group_ids}}
        end
      end)

    if left != 0, do: raise("cash allocation underflow")
    Enum.uniq(group_ids)
  end

  defp next_allocation_order do
    cash_max = Repo.one(from a in CashAllocation, select: max(a.allocation_order)) || 0
    credit_max = Repo.one(from a in CreditApplication, select: max(a.allocation_order)) || 0
    max(cash_max, credit_max) + 1
  end

  defp increment_changed_groups!(
         addressed_group_id,
         changed_group_ids,
         attrs_fun \\ fn _ -> %{} end
       ) do
    [addressed_group_id | changed_group_ids]
    |> Enum.uniq()
    |> Map.new(fn group_id ->
      group = Repo.get!(Group, group_id)
      attrs = Map.put(attrs_fun.(group), :revision, group.revision + 1)
      {group_id, sync_group_totals!(group, attrs)}
    end)
  end

  defp held_for_payment(account_id) do
    Repo.one(
      from a in CashAllocation,
        where: a.payment_account_id == ^account_id,
        select: coalesce(sum(a.amount_cents), 0)
    )
  end

  defp room_paid(room_id) do
    cash =
      Repo.one(
        from a in CashAllocation,
          where: a.room_id == ^room_id,
          select: coalesce(sum(a.amount_cents), 0)
      )

    credit =
      Repo.one(
        from a in CreditApplication,
          where: a.room_id == ^room_id,
          select: coalesce(sum(a.amount_cents), 0)
      )

    cash + credit
  end

  defp active_rooms(group_id) do
    Repo.all(
      from r in Room,
        where: r.group_id == ^group_id and r.status == "active",
        order_by: r.position
    )
  end

  defp sync_group_totals!(group, extra) do
    rooms = active_rooms(group.id)
    room_ids = Enum.map(rooms, & &1.id)

    cash = allocation_sum(CashAllocation, room_ids)
    credit = allocation_sum(CreditApplication, room_ids)

    attrs = %{
      lodging_total_cents: Enum.sum(Enum.map(rooms, & &1.lodging_total_cents)),
      deposit_due_cents: Enum.sum(Enum.map(rooms, & &1.deposit_due_cents)),
      cash_paid_cents: cash,
      credit_paid_cents: credit,
      deposit_paid_cents: cash + credit
    }

    update_group!(group, Map.merge(attrs, extra))
  end

  defp allocation_sum(_schema, []), do: 0

  defp allocation_sum(schema, room_ids) do
    Repo.one(
      from a in schema, where: a.room_id in ^room_ids, select: coalesce(sum(a.amount_cents), 0)
    )
  end

  defp payment_account_for_record(
         %OperationRecord{operation_type: "record_cash_payment"} = record
       ) do
    if result_value(record.result, "status") == "applied" do
      Repo.get_by(PaymentAccount, operation_id: record.operation_id) ||
        create_payment_account!(record)
    end
  end

  defp payment_account_for_record(_), do: nil

  defp create_payment_account!(record) do
    group_id = result_value(record.result, "group_id")
    amount = result_value(record.result, "amount_cents")
    group = Repo.get(Group, group_id)

    if is_binary(group_id) and is_integer(amount) and group do
      disposition =
        cond do
          group.status == "active" -> %{}
          group.cash_converted_to_credit_cents > 0 -> %{converted_cents: amount}
          group.cash_refunded_cents > 0 -> %{refunded_cents: amount}
          true -> %{retained_cents: amount}
        end

      account =
        %PaymentAccount{
          operation_record_id: record.id,
          operation_id: record.operation_id,
          group_id: group_id,
          recorded_cents: amount
        }
        |> Ecto.Changeset.change(disposition)
        |> Repo.insert!()

      Enum.each(disposition, fn {field, disposed_amount} ->
        Repo.insert!(%CashDisposition{
          payment_account_id: account.id,
          group_id: group_id,
          kind: disposition_kind(field),
          amount_cents: disposed_amount
        })
      end)

      account
    end
  end

  defp result_value(map, key), do: Map.get(map, key) || Map.get(map, String.to_existing_atom(key))

  defp ensure_room_accounting!(group) do
    rooms = Repo.all(from r in Room, where: r.group_id == ^group.id, order_by: r.position)
    records = funding_records(group.id)

    Enum.each(records, fn record ->
      if record.operation_type == "record_cash_payment", do: payment_account_for_record(record)
    end)

    if group.status == "active" do
      allocated_cash =
        Repo.one(
          from a in CashAllocation,
            where: a.group_id == ^group.id,
            select: coalesce(sum(a.amount_cents), 0)
        )

      unassigned_credit =
        Repo.exists?(
          from a in CreditApplication, where: a.group_id == ^group.id and is_nil(a.room_id)
        )

      if allocated_cash < group.cash_paid_cents or unassigned_credit do
        rebuild_legacy_allocations!(group, rooms, records, allocated_cash)
      end
    else
      reconstruct_conversion_entitlements!(group, records)
    end

    :ok
  end

  defp reconstruct_conversion_entitlements!(group, records) do
    accounts =
      records
      |> Enum.filter(&(&1.operation_type == "record_cash_payment"))
      |> Enum.map(&Repo.get_by(PaymentAccount, operation_id: &1.operation_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&(&1.converted_cents > 0))

    if accounts != [] do
      cancellation_ids =
        Repo.all(
          from r in OperationRecord,
            where: r.operation_type in ["cancel_group", "cancel_rooms"],
            order_by: r.id
        )
        |> Enum.filter(
          &(result_value(&1.result, "status") == "applied" and
              result_value(&1.result, "group_id") == group.id)
        )
        |> Enum.map(& &1.operation_id)

      Repo.all(from l in CreditLot, where: l.source_operation_id in ^cancellation_ids)
      |> Enum.each(fn lot ->
        existing =
          Repo.aggregate(from(e in CreditEntitlement, where: e.credit_lot_id == ^lot.id), :count)

        if existing == 0 do
          durable_cash = Enum.sum(Enum.map(accounts, & &1.converted_cents))
          legacy_cash = max(group.cash_converted_to_credit_cents - durable_cash, 0)
          contributions = [{nil, legacy_cash} | Enum.map(accounts, &{&1.id, &1.converted_cents})]
          add_entitlement_contributions!(lot, contributions)
        end
      end)
    end
  end

  defp add_entitlement_contributions!(lot, contributions) do
    Enum.reduce(contributions, 0, fn {account_id, cash}, running ->
      entitlement = cash + round_percent(running + cash, 10) - round_percent(running, 10)

      if account_id && entitlement > 0 do
        Repo.insert!(%CreditEntitlement{
          credit_lot_id: lot.id,
          payment_account_id: account_id,
          amount_cents: entitlement
        })
      end

      running + cash
    end)
  end

  defp funding_records(group_id) do
    Repo.all(
      from r in OperationRecord,
        where: r.operation_type in ["record_cash_payment", "apply_hotel_credit"],
        order_by: r.id
    )
    |> Enum.filter(fn record ->
      result_value(record.result, "status") == "applied" and
        result_value(record.result, "group_id") == group_id
    end)
  end

  defp rebuild_legacy_allocations!(group, _rooms, records, allocated_cash) do
    cash_records = Enum.filter(records, &(&1.operation_type == "record_cash_payment"))
    durable_cash = Enum.sum(Enum.map(cash_records, &result_value(&1.result, "amount_cents")))
    legacy_cash = max(group.cash_paid_cents - durable_cash - allocated_cash, 0)

    old_apps =
      Repo.all(from a in CreditApplication, where: a.group_id == ^group.id, order_by: a.id)

    chunks = Enum.map(old_apps, &{&1.credit_lot_id, &1.amount_cents})
    Enum.each(old_apps, &Repo.delete!/1)

    durable_credit =
      records
      |> Enum.filter(&(&1.operation_type == "apply_hotel_credit"))
      |> Enum.map(&result_value(&1.result, "amount_cents"))
      |> Enum.sum()

    legacy_credit = max(group.credit_paid_cents - durable_credit, 0)

    if legacy_cash > 0, do: allocate_cash!(group, nil, legacy_cash)
    {chunks, _} = allocate_old_credit!(group, chunks, nil, legacy_credit)

    chunks =
      Enum.reduce(records, chunks, fn record, remaining_chunks ->
        amount = result_value(record.result, "amount_cents")

        if record.operation_type == "record_cash_payment" do
          account = Repo.get_by!(PaymentAccount, operation_id: record.operation_id)
          allocate_cash!(group, account, amount)
          remaining_chunks
        else
          {rest, _} = allocate_old_credit!(group, remaining_chunks, record.operation_id, amount)
          rest
        end
      end)

    if chunks != [], do: raise("unallocated legacy credit chunks")
  end

  defp allocate_old_credit!(group, chunks, operation_id, amount) do
    Enum.reduce_while(chunks, {[], amount}, fn {lot_id, chunk}, {kept, left} ->
      cond do
        left == 0 ->
          {:halt, {Enum.reverse(kept) ++ [{lot_id, chunk}], 0}}

        chunk <= left ->
          allocate_credit_chunk!(group, lot_id, operation_id, chunk)
          {:cont, {kept, left - chunk}}

        true ->
          allocate_credit_chunk!(group, lot_id, operation_id, left)
          {:halt, {Enum.reverse(kept) ++ [{lot_id, chunk - left}], 0}}
      end
    end)
  end

  defp credit_shortfall do
    Repo.all(from l in CreditLot, where: l.unrecovered_clawback_cents > 0)
    |> Enum.map(fn lot ->
      applied =
        Repo.one(
          from a in CreditApplication,
            join: r in Room,
            on: r.id == a.room_id,
            where: a.credit_lot_id == ^lot.id and r.status == "active",
            select: coalesce(sum(a.amount_cents), 0)
        )

      min(lot.unrecovered_clawback_cents, applied)
    end)
    |> Enum.sum()
  end

  defp round_percent(amount, percent), do: div(amount * percent + 50, 100)

  defp refundable?(group, occurred_on) do
    until_date = refundable_until(group)
    not is_nil(until_date) and Date.compare(occurred_on, until_date) != :gt
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp update_credit_lot!(lot, attrs) do
    lot |> Ecto.Changeset.change(attrs) |> Repo.update!()
  end

  defp update_payment!(payment, attrs) do
    payment |> Ecto.Changeset.change(attrs) |> Repo.update!()
  end

  defp update_room!(room, attrs) do
    room |> Ecto.Changeset.change(attrs) |> Repo.update!()
  end

  defp update_group!(group, attrs) do
    group |> Ecto.Changeset.change(attrs) |> Repo.update!()
  end

  defp disposition_kind(:refunded_cents), do: "refunded"
  defp disposition_kind(:retained_cents), do: "retained"
  defp disposition_kind(:converted_cents), do: "converted"

  defp stale_result(group, expected_revision) do
    {:rejected, "stale_revision",
     %{
       group_id: group.id,
       expected_revision: expected_revision,
       actual_revision: group.revision
     }}
  end

  defp stale_revision?(operation, group) do
    stale_revision?(operation, group, "expected_revision")
  end

  defp invalid_expected_revision?(operation) do
    invalid_expected_revision?(operation, "expected_revision")
  end

  defp stale_revision?(operation, group, field) do
    Map.has_key?(operation, field) and operation[field] != group.revision and
      is_integer(operation[field])
  end

  defp invalid_expected_revision?(operation, field) do
    Map.has_key?(operation, field) and not is_integer(operation[field])
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn
        %{"room_id" => room_id, "nightly_rate_cents" => rate}
        when is_binary(room_id) and room_id != "" and is_integer(rate) and rate > 0 ->
          true

        _ ->
          false
      end)

    ids = Enum.map(rooms, &Map.get(&1, "room_id"))

    if valid and Enum.uniq(ids) == ids do
      {:ok,
       Enum.map(rooms, &%{room_id: &1["room_id"], nightly_rate_cents: &1["nightly_rate_cents"]})}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp validate_rooms(_), do: {:error, "invalid_rooms"}

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: {:ok, rate_plan}
  defp validate_rate_plan(_), do: {:error, "invalid_rate_plan"}

  defp valid_stay(arrival, departure) do
    if Date.compare(departure, arrival) == :gt, do: :ok, else: {:error, "invalid_stay"}
  end

  defp parse_date(value, code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, code}
    end
  end

  defp parse_date(_, code), do: {:error, code}

  defp require_fields(operation, fields) do
    if Enum.all?(fields, &Map.has_key?(operation, &1)),
      do: :ok,
      else: {:error, "invalid_operation"}
  end

  defp require_nonempty_strings(operation, fields) do
    if Enum.all?(fields, &(is_binary(operation[&1]) and operation[&1] != "")),
      do: :ok,
      else: {:error, "invalid_operation"}
  end

  defp format_result(operation_id, {:applied, fields}) do
    fields |> Map.put(:operation_id, operation_id) |> Map.put(:status, "applied")
  end

  defp format_result(operation_id, {:rejected, code, fields}) do
    fields
    |> Map.put(:operation_id, operation_id)
    |> Map.put(:status, "rejected")
    |> Map.put(:code, code)
  end
end
