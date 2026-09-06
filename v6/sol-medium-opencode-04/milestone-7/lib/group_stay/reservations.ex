defmodule GroupStay.Reservations do
  import Ecto.Query

  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    AllocationOrder,
    CashAllocation,
    CashPayment,
    CashSettlement,
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    FinanceCashMovement,
    FinanceCashOpening,
    FinanceCreditMovement,
    FinancePeriodClose,
    FinanceReportingStart,
    Group,
    Operation,
    PaymentTransferParticipation,
    Room
  }

  @rate_plans ["flexible", "advance_purchase"]
  @cash_movement_fields ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)a
  @credit_movement_fields ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)a

  def process(%{"operation_id" => operation_id} = operation)
      when is_binary(operation_id) and operation_id != "" do
    {:ok, result} =
      Repo.transact(fn -> {:ok, process_durable(operation_id, operation)} end, mode: :immediate)

    result
  end

  def process(operation) when is_map(operation),
    do: rejected_result(operation["operation_id"], %{"code" => "invalid_operation"})

  def process(_operation),
    do: %{"operation_id" => nil, "status" => "rejected", "code" => "invalid_operation"}

  def get_operation(operation_id) when is_binary(operation_id),
    do: Repo.get_by(Operation, operation_id: operation_id)

  def get_operation(_operation_id), do: nil

  def get_group(group_id) when is_binary(group_id) do
    Repo.transact(fn ->
      case Repo.get_by(Group, group_id: group_id) do
        nil ->
          {:ok, nil}

        group ->
          group = ensure_accounting!(group)
          {:ok, Repo.preload(group, :rooms, force: true)}
      end
    end)
    |> elem(1)
  end

  def get_group(_group_id), do: nil

  def group_json(%Group{} = group) do
    rooms = Enum.sort_by(group.rooms, & &1.position)
    room_data = Enum.map(rooms, &room_json/1)
    active = Enum.filter(room_data, &(&1["status"] == "active"))
    cash = Enum.sum_by(active, & &1["cash_paid_cents"])
    credit = Enum.sum_by(active, & &1["credit_paid_cents"])
    due = Enum.sum_by(active, & &1["deposit_due_cents"])

    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "revision" => group.revision,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "policy_version" => group.policy_version,
      "refundable_until" => format_date(refundable_until(group)),
      "status" => group.status,
      "rooms" => room_data,
      "lodging_total_cents" => Enum.sum_by(active, & &1["lodging_total_cents"]),
      "deposit_due_cents" => due,
      "deposit_paid_cents" => cash + credit,
      "cash_paid_cents" => cash,
      "credit_paid_cents" => credit,
      "outstanding_deposit_cents" => max(due - cash - credit, 0)
    }
  end

  def get_payment(operation_id) when is_binary(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil ->
        :not_found

      operation ->
        ensure_operation_group_accounting!(operation)

        case Repo.get_by(CashPayment, operation_id: operation.operation_id) do
          nil -> :not_reconcilable
          payment -> {:ok, payment_json(payment)}
        end
    end
  end

  def get_payment(_operation_id), do: :not_found

  def report_date(%{"on" => on}) when is_binary(on) do
    case Date.from_iso8601(on) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  def report_date(%{"on" => _}), do: :error
  def report_date(_params), do: {:ok, Date.utc_today()}

  def ledger(on \\ Date.utc_today()) do
    ensure_all_accounting!()

    cash =
      Repo.one(
        from p in CashPayment,
          select:
            {coalesce(sum(p.refunded_cents), 0), coalesce(sum(p.retained_cents), 0),
             coalesce(sum(p.converted_to_credit_cents), 0), coalesce(sum(p.reduced_cents), 0),
             coalesce(sum(p.charged_back_cents), 0)}
      )

    held = Repo.one(from a in CashAllocation, select: coalesce(sum(a.amount_cents), 0))
    {refunded, retained, converted, reduced, charged_back} = cash

    available_credit =
      Repo.one(
        from l in CreditLot,
          where: l.issued_on <= ^on and l.expires_on >= ^on,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    allocated_credit =
      Repo.one(from a in CreditAllocation, select: coalesce(sum(a.amount_cents), 0))

    shortfall =
      Repo.all(from l in CreditLot, where: l.unrecovered_clawback_cents > 0)
      |> Enum.sum_by(fn lot ->
        applied =
          Repo.one(
            from a in CreditAllocation,
              where: a.credit_lot_id == ^lot.id,
              select: coalesce(sum(a.amount_cents), 0)
          )

        min(lot.unrecovered_clawback_cents, applied)
      end)

    %{
      "cash_held_cents" => held,
      "cash_refunded_cents" => refunded,
      "cash_retained_cents" => retained,
      "cash_converted_to_credit_cents" => converted,
      "cash_reduced_cents" => reduced,
      "cash_charged_back_cents" => charged_back,
      "credit_liability_cents" => available_credit + allocated_credit,
      "credit_shortfall_cents" => shortfall
    }
  end

  def guest_credit(guest_id, on \\ Date.utc_today()) do
    lots = available_lots(guest_id, on)

    %{
      "guest_id" => guest_id,
      "available_cents" => Enum.sum_by(lots, & &1.remaining_cents),
      "lots" =>
        Enum.map(lots, fn lot ->
          %{
            "source_operation_id" => lot.source_operation_id,
            "remaining_cents" => lot.remaining_cents,
            "expires_on" => Date.to_iso8601(lot.expires_on)
          }
        end)
    }
  end

  def daily_finance_report(date) do
    Repo.transact(fn -> {:ok, do_daily_finance_report(date)} end)
    |> elem(1)
  end

  defp do_daily_finance_report(date) do
    case Repo.one(from s in FinanceReportingStart, limit: 1) do
      nil ->
        :report_not_available

      start ->
        if Date.before?(date, start.starts_on) do
          :report_not_available
        else
          {cash, late_cash} = daily_cash_report(start, date)
          {credit, late_credit} = daily_credit_report(start, date)
          latest_close = latest_finance_close()

          {:ok,
           %{
             "date" => Date.to_iso8601(date),
             "status" =>
               if(latest_close && not Date.after?(date, latest_close.period_end_on),
                 do: "closed",
                 else: "open"
               ),
             "cash" => cash,
             "credit" => credit,
             "late_adjustments" => %{
               "cash" => late_cash,
               "credit" => stringify_fields(late_credit)
             }
           }}
        end
    end
  end

  # Called by the request-04 migration after the new allocation tables exist.
  def backfill_accounting! do
    ensure_all_accounting!()
  end

  defp process_durable(operation_id, submission) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      %Operation{submission: stored_submission, result: result} ->
        if stored_submission === submission,
          do: result,
          else: rejected_result(operation_id, %{"code" => "operation_id_conflict"})

      nil ->
        result = execute(submission, operation_id)
        operation_type = if is_binary(submission["type"]), do: submission["type"]

        Repo.insert!(
          Operation.changeset(%Operation{}, %{
            operation_id: operation_id,
            operation_type: operation_type,
            submission: submission,
            result: result
          })
        )

        result
    end
  end

  defp execute(operation, operation_id) do
    case apply_operation(operation) do
      {:ok, fields} ->
        fields |> Map.put("status", "applied") |> Map.put("operation_id", operation_id)

      {:error, fields} ->
        rejected_result(operation_id, fields)
    end
  end

  defp rejected_result(operation_id, fields),
    do: fields |> Map.put("status", "rejected") |> Map.put("operation_id", operation_id)

  defp apply_operation(%{
         "operation_id" => operation_id,
         "type" => "start_finance_reporting",
         "starts_on" => starts_on
       })
       when is_binary(operation_id) and operation_id != "" and is_binary(starts_on) do
    case Date.from_iso8601(starts_on) do
      {:ok, date} -> start_finance_reporting(operation_id, date)
      _ -> reject("invalid_reporting_date")
    end
  end

  defp apply_operation(%{"type" => "start_finance_reporting"}),
    do: reject("invalid_reporting_date")

  defp apply_operation(%{
         "operation_id" => operation_id,
         "type" => "close_finance_period",
         "period_end_on" => period_end_on
       })
       when is_binary(operation_id) and operation_id != "" and is_binary(period_end_on) do
    case Date.from_iso8601(period_end_on) do
      {:ok, date} -> close_finance_period(operation_id, date)
      _ -> reject("invalid_period")
    end
  end

  defp apply_operation(%{"type" => "close_finance_period"}), do: reject("invalid_period")

  defp apply_operation(
         %{"operation_id" => operation_id, "type" => type, "occurred_on" => occurred_on} = op
       )
       when is_binary(operation_id) and operation_id != "" and is_binary(type) and
              is_binary(occurred_on) do
    with {:ok, date} <- Date.from_iso8601(occurred_on) do
      case type do
        "open_group" ->
          open_group(op, date)

        "record_cash_payment" ->
          with_group(op, &record_cash_payment(&1, op))

        "apply_hotel_credit" ->
          with_group(op, &apply_hotel_credit(&1, op, date))

        "reschedule_group" ->
          with_group(op, &reschedule_group(&1, op, date))

        "cancel_group" ->
          with_group(op, &cancel_group(&1, op, date))

        "cancel_rooms" ->
          with_group(op, &cancel_rooms(&1, op, date))

        "reduce_cash_payment" ->
          with_payment_target(op, "payment_not_reducible", &reduce_cash(&1, &2, op))

        "charge_back_payment" ->
          with_payment_target(op, "payment_not_chargeable", &charge_back(&1, &2, op))

        "transfer_deposit" ->
          with_transfer_groups(op, &transfer_deposit(&1, &2, op))

        _ ->
          reject("invalid_operation")
      end
    else
      _ -> reject("invalid_operation")
    end
  end

  defp apply_operation(_operation), do: reject("invalid_operation")

  defp start_finance_reporting(operation_id, starts_on) do
    if Repo.exists?(FinanceReportingStart) do
      reject("reporting_already_started")
    else
      ensure_all_accounting!()

      opening_credit = current_credit_liability(starts_on)

      Repo.insert!(
        FinanceReportingStart.changeset(%FinanceReportingStart{}, %{
          operation_id: operation_id,
          starts_on: starts_on,
          opening_credit_liability_cents: opening_credit
        })
      )

      opening_cash_by_property()
      |> Enum.each(fn {property_id, amount} ->
        Repo.insert!(
          FinanceCashOpening.changeset(%FinanceCashOpening{}, %{
            property_id: property_id,
            opening_held_cents: amount
          })
        )
      end)

      Repo.all(from l in CreditLot, where: l.remaining_cents > 0 and l.expires_on >= ^starts_on)
      |> Enum.each(fn lot ->
        record_credit_movement(operation_id, Date.add(lot.expires_on, 1), %{
          expired_cents: lot.remaining_cents
        })
      end)

      {:ok, %{"starts_on" => Date.to_iso8601(starts_on)}}
    end
  end

  defp close_finance_period(operation_id, period_end_on) do
    start = Repo.one(from s in FinanceReportingStart, limit: 1)
    latest_close = latest_finance_close()

    valid? =
      start && not Date.before?(period_end_on, start.starts_on) &&
        (is_nil(latest_close) or Date.after?(period_end_on, latest_close.period_end_on))

    if valid? do
      Repo.insert!(
        FinancePeriodClose.changeset(%FinancePeriodClose{}, %{
          operation_id: operation_id,
          period_end_on: period_end_on
        })
      )

      {:ok, %{"period_end_on" => Date.to_iso8601(period_end_on)}}
    else
      reject("invalid_period")
    end
  end

  defp open_group(op, booked_on) do
    required = ~w(group_id guest_id property_id arrival_on departure_on rate_plan rooms)

    if Enum.all?(required, &Map.has_key?(op, &1)),
      do: do_open_group(op, booked_on),
      else: reject("invalid_operation")
  end

  defp do_open_group(op, booked_on) do
    with :ok <- validate_identifier(op["group_id"]),
         :ok <- validate_identifier(op["guest_id"]),
         :ok <- validate_identifier(op["property_id"]),
         :ok <- validate_group_is_new(op["group_id"]),
         {:ok, arrival_on} <- parse_date(op["arrival_on"], "invalid_stay"),
         {:ok, departure_on} <- parse_date(op["departure_on"], "invalid_stay"),
         nights when nights > 0 <- Date.diff(departure_on, arrival_on),
         :ok <- validate_rate_plan(op["rate_plan"]),
         {:ok, rooms} <- validate_rooms(op["rooms"]) do
      room_amounts = Enum.map(rooms, &room_amounts(&1, nights, op["rate_plan"]))
      lodging = Enum.sum_by(room_amounts, & &1.lodging_total_cents)
      due = Enum.sum_by(room_amounts, & &1.deposit_due_cents)

      attrs = %{
        group_id: op["group_id"],
        guest_id: op["guest_id"],
        property_id: op["property_id"],
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: op["rate_plan"],
        policy_version: policy_version(op["rate_plan"], booked_on),
        status: "active",
        revision: 1,
        lodging_total_cents: lodging,
        deposit_due_cents: due,
        accounting_backfilled: true
      }

      case Repo.insert(Group.changeset(%Group{}, attrs)) do
        {:ok, group} ->
          room_amounts
          |> Enum.with_index()
          |> Enum.each(fn {room, position} ->
            room
            |> Map.from_struct()
            |> Map.merge(%{position: position, group_reservation_id: group.id, status: "active"})
            |> then(&Repo.insert!(Room.changeset(%Room{}, &1)))
          end)

          {:ok, %{"group_id" => group.group_id, "deposit_due_cents" => due, "revision" => 1}}

        {:error, changeset} ->
          if Keyword.has_key?(changeset.errors, :group_id),
            do: reject("group_already_exists"),
            else: reject("invalid_operation")
      end
    else
      {:error, code} -> reject(code)
      _ -> reject("invalid_stay")
    end
  end

  defp with_group(%{"group_id" => group_id} = op, callback)
       when is_binary(group_id) and group_id != "" do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        reject("group_not_found", %{"group_id" => group_id})

      group ->
        group = ensure_accounting!(group)

        case check_revision(group, op),
          do: (
            :ok -> callback.(group)
            error -> error
          )
    end
  end

  defp with_group(_op, _callback), do: reject("invalid_operation")

  defp with_payment_target(%{"payment_operation_id" => operation_id} = op, invalid_code, callback)
       when is_binary(operation_id) and operation_id != "" do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil ->
        reject("operation_not_found")

      operation ->
        ensure_operation_group_accounting!(operation)
        payment = Repo.get_by(CashPayment, operation_id: operation.operation_id)

        if payment do
          group = Repo.get!(Group, payment.group_reservation_id) |> ensure_accounting!()
          payment = Repo.get_by!(CashPayment, operation_id: operation.operation_id)

          case check_revision(group, op),
            do: (
              :ok -> callback.(payment, group)
              error -> error
            )
        else
          reject(invalid_code)
        end
    end
  end

  defp with_payment_target(_op, _invalid_code, _callback), do: reject("invalid_operation")

  defp with_transfer_groups(
         %{"source_group_id" => source_id, "destination_group_id" => destination_id} = op,
         callback
       )
       when is_binary(source_id) and source_id != "" and is_binary(destination_id) and
              destination_id != "" do
    case Repo.get_by(Group, group_id: source_id) do
      nil ->
        reject("group_not_found", %{"group_id" => source_id})

      source ->
        source = ensure_accounting!(source)

        case Repo.get_by(Group, group_id: destination_id) do
          nil ->
            reject("group_not_found", %{"group_id" => destination_id})

          destination ->
            destination = ensure_accounting!(destination)

            with :ok <- check_revision(source, op),
                 :ok <- check_destination_revision(destination, op) do
              callback.(source, destination)
            end
        end
    end
  end

  defp with_transfer_groups(_op, _callback), do: reject("invalid_operation")

  defp check_revision(group, %{"expected_revision" => expected}) when is_integer(expected) do
    if expected == group.revision do
      :ok
    else
      reject("stale_revision", %{
        "group_id" => group.group_id,
        "expected_revision" => expected,
        "actual_revision" => group.revision
      })
    end
  end

  defp check_revision(_group, %{"expected_revision" => _}), do: reject("invalid_operation")
  defp check_revision(_group, _op), do: :ok

  defp check_destination_revision(group, %{"destination_expected_revision" => expected})
       when is_integer(expected) do
    if expected == group.revision do
      :ok
    else
      reject("stale_revision", %{
        "group_id" => group.group_id,
        "expected_revision" => expected,
        "actual_revision" => group.revision
      })
    end
  end

  defp check_destination_revision(_group, %{"destination_expected_revision" => _}),
    do: reject("invalid_operation")

  defp check_destination_revision(_group, _op), do: :ok

  defp transfer_deposit(source, destination, op) do
    held = held_funding(source.id)

    cond do
      not Map.has_key?(op, "amount_cents") ->
        reject("invalid_operation")

      source.status != "active" ->
        reject("group_not_active", %{"group_id" => source.group_id})

      destination.status != "active" ->
        reject("group_not_active", %{"group_id" => destination.group_id})

      source.id == destination.id or source.guest_id != destination.guest_id ->
        reject("invalid_transfer")

      not positive_integer?(op["amount_cents"]) ->
        reject("invalid_amount")

      op["amount_cents"] > held ->
        reject("transfer_exceeds_held_funding")

      op["amount_cents"] > outstanding(destination) ->
        reject("transfer_exceeds_outstanding")

      true ->
        amount = op["amount_cents"]
        chunks = draw_funding!(source.id, amount)
        allocate_transfer_chunks!(active_rooms(destination.id), destination.id, chunks)
        cash_amount = chunks |> Enum.filter(&(&1.kind == :cash)) |> Enum.sum_by(& &1.amount_cents)

        record_cash_movement(op, source.property_id, %{transferred_out_cents: cash_amount})
        record_cash_movement(op, destination.property_id, %{transferred_in_cents: cash_amount})

        updated_source = sync_group!(source)
        updated_destination = sync_group!(destination)

        {:ok,
         %{
           "source_group_id" => source.group_id,
           "destination_group_id" => destination.group_id,
           "amount_cents" => amount,
           "source_outstanding_deposit_cents" => outstanding(updated_source),
           "destination_outstanding_deposit_cents" => outstanding(updated_destination),
           "source_revision" => updated_source.revision,
           "destination_revision" => updated_destination.revision
         }}
    end
  end

  defp record_cash_payment(group, op) do
    cond do
      not Map.has_key?(op, "amount_cents") ->
        reject("invalid_operation")

      group.status != "active" ->
        reject("group_not_active", %{"group_id" => group.group_id})

      not positive_integer?(op["amount_cents"]) ->
        reject("invalid_amount")

      op["amount_cents"] > outstanding(group) ->
        reject("payment_exceeds_outstanding")

      true ->
        amount = op["amount_cents"]

        payment =
          Repo.insert!(
            CashPayment.changeset(%CashPayment{}, %{
              operation_id: op["operation_id"],
              group_reservation_id: group.id,
              recorded_cents: amount
            })
          )

        allocate_cash!(payment, active_rooms(group.id), amount)
        record_cash_movement(op, group.property_id, %{received_cents: amount})
        updated = sync_group!(group)

        {:ok,
         %{
           "group_id" => group.group_id,
           "amount_cents" => amount,
           "outstanding_deposit_cents" => outstanding(updated),
           "revision" => updated.revision
         }}
    end
  end

  defp apply_hotel_credit(group, op, occurred_on) do
    cond do
      not Map.has_key?(op, "amount_cents") ->
        reject("invalid_operation")

      group.status != "active" ->
        reject("group_not_active", %{"group_id" => group.group_id})

      not positive_integer?(op["amount_cents"]) ->
        reject("invalid_amount")

      op["amount_cents"] > outstanding(group) ->
        reject("payment_exceeds_outstanding")

      true ->
        lots = available_lots(group.guest_id, occurred_on)
        amount = op["amount_cents"]

        if Enum.sum_by(lots, & &1.remaining_cents) < amount do
          reject("insufficient_credit")
        else
          consumed = consume_credit!(lots, group, op["operation_id"], amount)

          Enum.each(consumed, fn {lot, used} ->
            record_expiry_adjustment(op, lot.expires_on, -used)
          end)

          updated = sync_group!(group)

          {:ok,
           %{
             "group_id" => group.group_id,
             "amount_cents" => amount,
             "outstanding_deposit_cents" => outstanding(updated),
             "revision" => updated.revision
           }}
        end
    end
  end

  defp reschedule_group(group, op, occurred_on) do
    cond do
      not Map.has_key?(op, "new_arrival_on") ->
        reject("invalid_operation")

      group.status != "active" ->
        reject("group_not_active", %{"group_id" => group.group_id})

      true ->
        with {:ok, new_arrival} <- parse_date(op["new_arrival_on"], "invalid_stay"),
             true <- Date.after?(new_arrival, occurred_on) do
          shift = Date.diff(new_arrival, group.arrival_on)

          updated =
            update_group!(group, %{
              arrival_on: new_arrival,
              departure_on: Date.add(group.departure_on, shift)
            })

          {:ok,
           %{
             "group_id" => group.group_id,
             "new_arrival_on" => Date.to_iso8601(updated.arrival_on),
             "new_departure_on" => Date.to_iso8601(updated.departure_on),
             "policy_version" => updated.policy_version,
             "refundable_until" => format_date(refundable_until(updated)),
             "revision" => updated.revision
           }}
        else
          _ -> reject("invalid_stay")
        end
    end
  end

  defp cancel_group(group, op, occurred_on) do
    if group.status != "active" do
      reject("group_not_active", %{"group_id" => group.group_id})
    else
      settle_rooms(group, active_rooms(group.id), op, occurred_on, false)
    end
  end

  defp cancel_rooms(group, op, occurred_on) do
    cond do
      group.status != "active" ->
        reject("group_not_active", %{"group_id" => group.group_id})

      not Map.has_key?(op, "room_ids") ->
        reject("invalid_operation")

      not is_list(op["room_ids"]) or op["room_ids"] == [] ->
        reject("invalid_rooms")

      true ->
        requested = op["room_ids"]
        rooms = active_rooms(group.id) |> Enum.filter(&(&1.room_id in requested))

        if Enum.uniq(requested) != requested or length(rooms) != length(requested),
          do: reject("invalid_rooms"),
          else: settle_rooms(group, rooms, op, occurred_on, true)
    end
  end

  defp settle_rooms(group, rooms, op, occurred_on, include_room_ids) do
    refund_method = Map.get(op, "refund_method", "cash")

    cond do
      refund_method not in ["cash", "hotel_credit"] ->
        reject("invalid_operation")

      refund_method == "hotel_credit" and not refundable?(group, occurred_on) ->
        reject("refund_method_not_available")

      true ->
        do_settle_rooms(group, rooms, op, refund_method, occurred_on, include_room_ids)
    end
  end

  defp do_settle_rooms(group, rooms, op, refund_method, occurred_on, include_room_ids) do
    refundable = refundable?(group, occurred_on)
    room_ids = Enum.map(rooms, & &1.id)

    ordered_allocations =
      Repo.all(
        from a in CashAllocation,
          join: p in assoc(a, :cash_payment),
          join: o in AllocationOrder,
          on: o.kind == "cash" and o.allocation_id == a.id,
          where: a.group_room_id in ^room_ids,
          order_by: o.id,
          select: {a, p}
      )

    contributions =
      Enum.map(ordered_allocations, fn {allocation, payment} ->
        {payment, allocation.amount_cents}
      end)

    cash_amount = Enum.sum_by(contributions, &elem(&1, 1))
    {refunded, retained, converted} = settlement_amounts(cash_amount, refundable, refund_method)

    contributions
    |> Enum.group_by(fn {payment, _amount} -> payment.id end)
    |> Enum.each(fn {_payment_id, payment_contributions} ->
      {payment, _} = hd(payment_contributions)
      amount = Enum.sum_by(payment_contributions, &elem(&1, 1))

      attrs =
        cond do
          refunded > 0 ->
            %{refunded_cents: payment.refunded_cents + amount}

          retained > 0 ->
            %{retained_cents: payment.retained_cents + amount}

          converted > 0 ->
            %{converted_to_credit_cents: payment.converted_to_credit_cents + amount}

          true ->
            %{}
        end

      payment |> CashPayment.changeset(attrs) |> Repo.update!()

      record_cash_settlement!(payment.id, group.id, %{
        refunded_cents: if(refunded > 0, do: amount, else: 0),
        retained_cents: if(retained > 0, do: amount, else: 0),
        converted_to_credit_cents: if(converted > 0, do: amount, else: 0)
      })
    end)

    Enum.each(ordered_allocations, fn {allocation, _payment} ->
      delete_allocation!("cash", allocation)
    end)

    credit_issued =
      if converted > 0 do
        issue_credit!(group, op, occurred_on, contributions)
      else
        0
      end

    credit_movements = settle_credit_allocations!(room_ids, refundable, occurred_on, op)

    record_cash_movement(op, group.property_id, %{
      refunded_cents: refunded,
      retained_cents: retained,
      converted_to_credit_cents: converted
    })

    record_credit_movement(op, Map.put(credit_movements, :issued_cents, credit_issued))

    Enum.each(rooms, fn room ->
      room |> Room.changeset(%{status: "cancelled"}) |> Repo.update!()
    end)

    status =
      if Repo.exists?(
           from r in Room, where: r.group_reservation_id == ^group.id and r.status == "active"
         ), do: "active", else: "cancelled"

    updated =
      sync_group!(group, %{
        status: status,
        refunded_cents: group.refunded_cents + refunded,
        retained_cents: group.retained_cents + retained,
        cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted
      })

    result = %{
      "group_id" => group.group_id,
      "refunded_cents" => refunded,
      "retained_cents" => retained,
      "credit_issued_cents" => credit_issued,
      "revision" => updated.revision
    }

    if include_room_ids,
      do: {:ok, Map.put(result, "cancelled_room_ids", Enum.map(rooms, & &1.room_id))},
      else: {:ok, result}
  end

  defp reduce_cash(payment, group, op) do
    held = held_cash(payment.id)

    cond do
      not Map.has_key?(op, "amount_cents") ->
        reject("invalid_operation")

      held == 0 ->
        reject("payment_not_reducible")

      not positive_integer?(op["amount_cents"]) ->
        reject("invalid_amount")

      op["amount_cents"] > held ->
        reject("reduction_exceeds_held_cash")

      true ->
        amount = op["amount_cents"]
        affected = remove_cash_allocations!(payment.id, amount)

        Enum.each(affected, fn {group_id, removed} ->
          property_id = Repo.get!(Group, group_id).property_id
          record_cash_movement(op, property_id, %{reduced_cents: removed})
        end)

        payment
        |> CashPayment.changeset(%{reduced_cents: payment.reduced_cents + amount})
        |> Repo.update!()

        updated_groups =
          (Map.keys(affected) ++ [group.id])
          |> Enum.uniq()
          |> Enum.map(fn group_id ->
            current = Repo.get!(Group, group_id)

            attrs =
              if group_id == group.id,
                do: %{cash_reduced_cents: current.cash_reduced_cents + amount},
                else: %{}

            sync_group!(current, attrs)
          end)

        updated = Enum.find(updated_groups, &(&1.id == group.id))

        {:ok,
         %{
           "payment_operation_id" => payment.operation_id,
           "group_id" => group.group_id,
           "amount_cents" => amount,
           "outstanding_deposit_cents" => outstanding(updated),
           "revision" => updated.revision
         }}
    end
  end

  defp charge_back(payment, group, op) do
    remaining = payment.recorded_cents - payment.reduced_cents - payment.charged_back_cents

    if remaining <= 0 do
      reject("payment_not_chargeable")
    else
      held = held_cash(payment.id)
      held_by_group = remove_cash_allocations!(payment.id, held)

      settlements =
        Repo.all(from s in CashSettlement, where: s.cash_payment_id == ^payment.id)

      credit_movements = revoke_entitlements!(payment, op)

      payment
      |> CashPayment.changeset(%{
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0,
        charged_back_cents: payment.charged_back_cents + remaining
      })
      |> Repo.update!()

      settlement_by_group = Map.new(settlements, &{&1.group_reservation_id, &1})

      (Map.keys(held_by_group) ++ Map.keys(settlement_by_group))
      |> Enum.uniq()
      |> Enum.each(fn group_id ->
        current = Repo.get!(Group, group_id)
        settlement = Map.get(settlement_by_group, group_id, %CashSettlement{})

        record_cash_movement(op, current.property_id, %{
          refunded_cents: -settlement.refunded_cents,
          retained_cents: -settlement.retained_cents,
          converted_to_credit_cents: -settlement.converted_to_credit_cents,
          charged_back_cents:
            Map.get(held_by_group, group_id, 0) + settlement.refunded_cents +
              settlement.retained_cents + settlement.converted_to_credit_cents
        })
      end)

      record_credit_movement(op, credit_movements)

      updated_groups =
        (Map.keys(held_by_group) ++ Map.keys(settlement_by_group) ++ [group.id])
        |> Enum.uniq()
        |> Enum.map(fn group_id ->
          current = Repo.get!(Group, group_id)
          settlement = Map.get(settlement_by_group, group_id, %CashSettlement{})

          charged_back =
            Map.get(held_by_group, group_id, 0) + settlement.refunded_cents +
              settlement.retained_cents + settlement.converted_to_credit_cents

          sync_group!(current, %{
            refunded_cents: current.refunded_cents - settlement.refunded_cents,
            retained_cents: current.retained_cents - settlement.retained_cents,
            cash_converted_to_credit_cents:
              current.cash_converted_to_credit_cents - settlement.converted_to_credit_cents,
            cash_charged_back_cents: current.cash_charged_back_cents + charged_back
          })
        end)

      Repo.delete_all(from s in CashSettlement, where: s.cash_payment_id == ^payment.id)
      updated = Enum.find(updated_groups, &(&1.id == group.id))

      {:ok,
       %{
         "payment_operation_id" => payment.operation_id,
         "group_id" => group.group_id,
         "charged_back_cents" => remaining,
         "outstanding_deposit_cents" => outstanding(updated),
         "revision" => updated.revision
       }}
    end
  end

  defp room_json(room) do
    cash =
      Repo.one(
        from a in CashAllocation,
          where: a.group_room_id == ^room.id,
          select: coalesce(sum(a.amount_cents), 0)
      )

    credit =
      Repo.one(
        from a in CreditAllocation,
          where: a.group_room_id == ^room.id,
          select: coalesce(sum(a.amount_cents), 0)
      )

    %{
      "room_id" => room.room_id,
      "nightly_rate_cents" => room.nightly_rate_cents,
      "status" => room.status,
      "lodging_total_cents" => room.lodging_total_cents,
      "deposit_due_cents" => room.deposit_due_cents,
      "cash_paid_cents" => cash,
      "credit_paid_cents" => credit
    }
  end

  defp allocate_cash!(payment, rooms, amount) do
    allocate_to_rooms(rooms, amount, fn room, used ->
      insert_cash_allocation!(payment.id, room.id, used)
    end)
  end

  defp consume_credit!(lots, group, operation_id, amount) do
    rooms = active_rooms(group.id)

    {_, lot_chunks} =
      Enum.reduce_while(lots, {amount, []}, fn lot, {remaining, chunks} ->
        used = min(lot.remaining_cents, remaining)

        lot
        |> CreditLot.changeset(%{remaining_cents: lot.remaining_cents - used})
        |> Repo.update!()

        next = {remaining - used, chunks ++ [{lot, used}]}
        if used == remaining, do: {:halt, next}, else: {:cont, next}
      end)

    allocate_credit_chunks!(rooms, lot_chunks, group.id, operation_id)
    lot_chunks
  end

  defp allocate_credit_chunks!(rooms, chunks, group_id, operation_id) do
    room_needs = Enum.map(rooms, &{&1, room_outstanding(&1)})

    Enum.reduce(chunks, room_needs, fn {lot, chunk_amount}, needs ->
      {next_needs, 0} =
        Enum.map_reduce(needs, chunk_amount, fn {room, need}, remaining ->
          used = min(need, remaining)

          if used > 0 do
            insert_credit_allocation!(
              lot.id,
              group_id,
              room.id,
              operation_id,
              used
            )
          end

          {{room, need - used}, remaining - used}
        end)

      next_needs
    end)
  end

  defp allocate_to_rooms(rooms, amount, inserter) do
    Enum.reduce_while(rooms, amount, fn room, remaining ->
      used = min(room_outstanding(room), remaining)
      if used > 0, do: inserter.(room, used)
      if used == remaining, do: {:halt, 0}, else: {:cont, remaining - used}
    end)
  end

  defp insert_cash_allocation!(payment_id, room_id, amount) do
    allocation =
      Repo.insert!(
        CashAllocation.changeset(%CashAllocation{}, %{
          cash_payment_id: payment_id,
          group_room_id: room_id,
          amount_cents: amount
        })
      )

    record_allocation_order!("cash", allocation.id)
    allocation
  end

  defp insert_credit_allocation!(lot_id, group_id, room_id, operation_id, amount) do
    allocation =
      Repo.insert!(
        CreditAllocation.changeset(%CreditAllocation{}, %{
          credit_lot_id: lot_id,
          group_reservation_id: group_id,
          group_room_id: room_id,
          funding_operation_id: operation_id,
          amount_cents: amount
        })
      )

    record_allocation_order!("credit", allocation.id)
    allocation
  end

  # Request 04 calls this module while migrating databases that do not have this table yet.
  defp record_allocation_order!(kind, allocation_id) do
    if allocation_ordering_available?() do
      Repo.insert!(
        AllocationOrder.changeset(%AllocationOrder{}, %{
          kind: kind,
          allocation_id: allocation_id
        })
      )
    end
  end

  defp allocation_ordering_available? do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'allocation_orders'"
      )

    count == 1
  end

  defp held_funding(group_id) do
    room_ids = Enum.map(active_rooms(group_id), & &1.id)

    cash =
      Repo.one(
        from a in CashAllocation,
          where: a.group_room_id in ^room_ids,
          select: coalesce(sum(a.amount_cents), 0)
      )

    credit =
      Repo.one(
        from a in CreditAllocation,
          where: a.group_room_id in ^room_ids,
          select: coalesce(sum(a.amount_cents), 0)
      )

    cash + credit
  end

  defp draw_funding!(group_id, amount) do
    cash =
      Repo.all(
        from a in CashAllocation,
          join: r in Room,
          on: r.id == a.group_room_id,
          join: o in AllocationOrder,
          on: o.kind == "cash" and o.allocation_id == a.id,
          where: r.group_reservation_id == ^group_id and r.status == "active",
          select: {o.id, a}
      )
      |> Enum.map(fn {order, allocation} ->
        {order, :cash, allocation, %{cash_payment_id: allocation.cash_payment_id}}
      end)

    credit =
      Repo.all(
        from a in CreditAllocation,
          join: r in Room,
          on: r.id == a.group_room_id,
          join: o in AllocationOrder,
          on: o.kind == "credit" and o.allocation_id == a.id,
          where: r.group_reservation_id == ^group_id and r.status == "active",
          select: {o.id, a}
      )
      |> Enum.map(fn {order, allocation} ->
        {order, :credit, allocation,
         %{
           credit_lot_id: allocation.credit_lot_id,
           funding_operation_id: allocation.funding_operation_id
         }}
      end)

    (cash ++ credit)
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.reduce_while({amount, []}, fn {_order, kind, allocation, provenance},
                                          {remaining, chunks} ->
      moved = min(allocation.amount_cents, remaining)

      if moved == allocation.amount_cents do
        Repo.delete_all(
          from o in AllocationOrder,
            where: o.kind == ^Atom.to_string(kind) and o.allocation_id == ^allocation.id
        )

        Repo.delete!(allocation)
      else
        allocation
        |> allocation_changeset(kind, allocation.amount_cents - moved)
        |> Repo.update!()
      end

      chunk = Map.merge(provenance, %{kind: kind, amount_cents: moved})
      next = {remaining - moved, chunks ++ [chunk]}
      if moved == remaining, do: {:halt, next}, else: {:cont, next}
    end)
    |> elem(1)
  end

  defp allocation_changeset(allocation, :cash, amount),
    do: CashAllocation.changeset(allocation, %{amount_cents: amount})

  defp allocation_changeset(allocation, :credit, amount),
    do: CreditAllocation.changeset(allocation, %{amount_cents: amount})

  defp allocate_transfer_chunks!(rooms, destination_group_id, chunks) do
    room_needs = Enum.map(rooms, &{&1, room_outstanding(&1)})

    Enum.reduce(chunks, room_needs, fn chunk, needs ->
      {next_needs, 0} =
        Enum.map_reduce(needs, chunk.amount_cents, fn {room, need}, remaining ->
          used = min(need, remaining)

          if used > 0 do
            case chunk.kind do
              :cash ->
                insert_cash_allocation!(chunk.cash_payment_id, room.id, used)
                mark_payment_transferred!(chunk.cash_payment_id)

              :credit ->
                insert_credit_allocation!(
                  chunk.credit_lot_id,
                  destination_group_id,
                  room.id,
                  chunk.funding_operation_id,
                  used
                )
            end
          end

          {{room, need - used}, remaining - used}
        end)

      next_needs
    end)
  end

  defp mark_payment_transferred!(payment_id) do
    %PaymentTransferParticipation{}
    |> PaymentTransferParticipation.changeset(%{cash_payment_id: payment_id})
    |> Repo.insert(on_conflict: :nothing, conflict_target: :cash_payment_id)
  end

  defp remove_cash_allocations!(_payment_id, 0), do: %{}

  defp remove_cash_allocations!(payment_id, amount) do
    allocations =
      Repo.all(
        from a in CashAllocation,
          join: r in Room,
          on: r.id == a.group_room_id,
          join: o in AllocationOrder,
          on: o.kind == "cash" and o.allocation_id == a.id,
          where: a.cash_payment_id == ^payment_id,
          order_by: [desc: o.id],
          select: {a, r.group_reservation_id}
      )

    Enum.reduce_while(allocations, {amount, %{}}, fn {allocation, group_id},
                                                     {remaining, affected} ->
      removed = min(allocation.amount_cents, remaining)

      if removed == allocation.amount_cents do
        delete_allocation!("cash", allocation)
      else
        allocation
        |> CashAllocation.changeset(%{amount_cents: allocation.amount_cents - removed})
        |> Repo.update!()
      end

      next = {remaining - removed, Map.update(affected, group_id, removed, &(&1 + removed))}
      if removed == remaining, do: {:halt, next}, else: {:cont, next}
    end)
    |> elem(1)
  end

  defp issue_credit!(group, op, occurred_on, contributions) do
    principal = Enum.sum_by(contributions, &elem(&1, 1))
    total = bonus_value(principal)

    lot =
      Repo.insert!(
        CreditLot.changeset(%CreditLot{}, %{
          guest_id: group.guest_id,
          source_operation_id: op["operation_id"],
          remaining_cents: total,
          issued_on: occurred_on,
          expires_on: Date.add(occurred_on, 365)
        })
      )

    {_running, _entitled, entitlement_by_payment} =
      Enum.reduce(contributions, {0, 0, %{}}, fn {payment, amount},
                                                 {running, entitled, by_payment} ->
        next_running = running + amount
        next_entitled = bonus_value(next_running)
        entitlement = next_entitled - entitled

        by_payment =
          if legacy_payment?(payment),
            do: by_payment,
            else: Map.update(by_payment, payment.id, entitlement, &(&1 + entitlement))

        {next_running, next_entitled, by_payment}
      end)

    Enum.each(entitlement_by_payment, fn {payment_id, amount} ->
      Repo.insert!(
        CreditEntitlement.changeset(%CreditEntitlement{}, %{
          credit_lot_id: lot.id,
          cash_payment_id: payment_id,
          amount_cents: amount
        })
      )
    end)

    record_expiry_adjustment(op, lot.expires_on, total)

    total
  end

  defp settle_credit_allocations!(room_ids, refundable, occurred_on, op) do
    Repo.all(
      from a in CreditAllocation, where: a.group_room_id in ^room_ids, preload: [:credit_lot]
    )
    |> Enum.reduce(%{expired_cents: 0, consumed_cents: 0, absorbed_cents: 0}, fn allocation,
                                                                                 totals ->
      effects =
        if refundable do
          lot = Repo.get!(CreditLot, allocation.credit_lot_id)
          restore_credit!(lot, allocation.amount_cents, occurred_on, op)
        else
          %{expired_cents: 0, consumed_cents: allocation.amount_cents, absorbed_cents: 0}
        end

      delete_allocation!("credit", allocation)

      Map.merge(totals, effects, fn _key, left, right -> left + right end)
    end)
  end

  defp record_cash_settlement!(payment_id, group_id, attrs) do
    settlement =
      Repo.get_by(CashSettlement,
        cash_payment_id: payment_id,
        group_reservation_id: group_id
      ) || %CashSettlement{cash_payment_id: payment_id, group_reservation_id: group_id}

    current = Map.from_struct(settlement)

    updates = %{
      refunded_cents: current.refunded_cents + attrs.refunded_cents,
      retained_cents: current.retained_cents + attrs.retained_cents,
      converted_to_credit_cents:
        current.converted_to_credit_cents + attrs.converted_to_credit_cents
    }

    settlement |> CashSettlement.changeset(updates) |> Repo.insert_or_update!()
  end

  defp delete_allocation!(kind, allocation) do
    if allocation_ordering_available?() do
      Repo.delete_all(
        from o in AllocationOrder,
          where: o.kind == ^kind and o.allocation_id == ^allocation.id
      )
    end

    Repo.delete!(allocation)
  end

  defp restore_credit!(lot, amount, occurred_on, op) do
    absorbed = min(lot.unrecovered_clawback_cents, amount)
    available = amount - absorbed
    unexpired = not Date.before?(lot.expires_on, occurred_on)
    record_expiry_adjustment(op, lot.expires_on, available)

    attrs = %{
      unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed,
      remaining_cents: lot.remaining_cents + if(unexpired, do: available, else: 0)
    }

    lot |> CreditLot.changeset(attrs) |> Repo.update!()
    %{expired_cents: 0, consumed_cents: 0, absorbed_cents: absorbed}
  end

  defp revoke_entitlements!(payment, op) do
    Repo.all(
      from e in CreditEntitlement, where: e.cash_payment_id == ^payment.id, preload: [:credit_lot]
    )
    |> Enum.reduce(%{revoked_cents: 0}, fn entitlement, totals ->
      amount = entitlement.amount_cents - entitlement.revoked_cents
      removed = min(entitlement.credit_lot.remaining_cents, amount)
      reporting_on = natural_reporting_date(op)
      unexpired = not Date.before?(entitlement.credit_lot.expires_on, reporting_on)
      if unexpired, do: record_expiry_adjustment(op, entitlement.credit_lot.expires_on, -removed)

      entitlement.credit_lot
      |> CreditLot.changeset(%{
        remaining_cents: entitlement.credit_lot.remaining_cents - removed,
        unrecovered_clawback_cents:
          entitlement.credit_lot.unrecovered_clawback_cents + amount - removed
      })
      |> Repo.update!()

      entitlement
      |> CreditEntitlement.changeset(%{revoked_cents: entitlement.revoked_cents + amount})
      |> Repo.update!()

      Map.update!(totals, :revoked_cents, &(&1 + if(unexpired, do: removed, else: 0)))
    end)
  end

  defp ensure_all_accounting! do
    Repo.all(from g in Group, where: g.accounting_backfilled == false)
    |> Enum.each(&ensure_accounting!/1)
  end

  defp ensure_accounting!(%Group{accounting_backfilled: true} = group), do: group

  defp ensure_accounting!(group) do
    rooms =
      Repo.all(from r in Room, where: r.group_reservation_id == ^group.id, order_by: r.position)

    durable =
      Repo.all(
        from o in Operation,
          where: o.operation_type == "record_cash_payment",
          order_by: o.id
      )
      |> Enum.filter(fn operation ->
        operation.result["status"] == "applied" and operation.result["group_id"] == group.group_id
      end)

    durable_total = Enum.sum_by(durable, & &1.result["amount_cents"])
    legacy_amount = max(group.cash_paid_cents - durable_total, 0)

    payments =
      if legacy_amount > 0 do
        [create_legacy_payment!(group, legacy_amount)]
      else
        []
      end ++
        Enum.map(durable, fn operation ->
          Repo.get_by(CashPayment, operation_id: operation.operation_id) ||
            Repo.insert!(
              CashPayment.changeset(%CashPayment{}, %{
                operation_id: operation.operation_id,
                group_reservation_id: group.id,
                recorded_cents: operation.result["amount_cents"]
              })
            )
        end)

    if group.status == "active" do
      backfill_active_funding!(group, rooms, payments, durable, legacy_amount)
    else
      classify_historical_payments!(payments, group)
      backfill_credit_allocations!(group, rooms)
    end

    group
    |> Group.changeset(%{accounting_backfilled: true})
    |> Repo.update!()
  end

  defp create_legacy_payment!(group, amount) do
    Repo.insert!(
      CashPayment.changeset(%CashPayment{}, %{
        operation_id: unique_legacy_operation_id(group.id),
        group_reservation_id: group.id,
        recorded_cents: amount
      })
    )
  end

  defp unique_legacy_operation_id(group_id, suffix \\ 0) do
    candidate = "__legacy__:#{group_id}:#{suffix}"

    if Repo.exists?(from o in Operation, where: o.operation_id == ^candidate) or
         Repo.exists?(from p in CashPayment, where: p.operation_id == ^candidate) do
      unique_legacy_operation_id(group_id, suffix + 1)
    else
      candidate
    end
  end

  defp backfill_active_funding!(group, rooms, payments, durable_cash, legacy_cash) do
    credit_rows =
      Repo.all(
        from a in CreditAllocation,
          where: a.group_reservation_id == ^group.id,
          order_by: a.id,
          preload: [:credit_lot]
      )

    Enum.each(credit_rows, &Repo.delete!/1)
    credit_chunks = Enum.map(credit_rows, &{&1.credit_lot, &1.amount_cents})

    durable_credit =
      Repo.all(
        from o in Operation, where: o.operation_type == "apply_hotel_credit", order_by: o.id
      )
      |> Enum.filter(fn operation ->
        operation.result["status"] == "applied" and operation.result["group_id"] == group.group_id
      end)

    durable_credit_total = Enum.sum_by(durable_credit, & &1.result["amount_cents"])
    legacy_credit = max(group.credit_paid_cents - durable_credit_total, 0)
    payment_by_operation = Map.new(payments, &{&1.operation_id, &1})

    if legacy_cash > 0 do
      allocate_cash!(Enum.find(payments, &legacy_payment?/1), rooms, legacy_cash)
    end

    {chunks, _used} =
      allocate_backfill_credit!(rooms, credit_chunks, legacy_credit, group.id, nil)

    (durable_cash ++ durable_credit)
    |> Enum.sort_by(& &1.id)
    |> Enum.reduce(chunks, fn operation, remaining_chunks ->
      if operation.operation_type == "record_cash_payment" do
        payment = Map.fetch!(payment_by_operation, operation.operation_id)
        allocate_cash!(payment, rooms, payment.recorded_cents)
        remaining_chunks
      else
        {rest, _used} =
          allocate_backfill_credit!(
            rooms,
            remaining_chunks,
            operation.result["amount_cents"],
            group.id,
            operation.operation_id
          )

        rest
      end
    end)
  end

  defp allocate_backfill_credit!(rooms, chunks, amount, group_id, operation_id) do
    {used, remaining} = take_credit_chunks(chunks, amount, [])
    allocate_credit_chunks!(rooms, used, group_id, operation_id)
    {remaining, used}
  end

  defp take_credit_chunks(chunks, 0, used), do: {Enum.reverse(used), chunks}

  defp take_credit_chunks([{lot, amount} | rest], needed, used) do
    consumed = min(amount, needed)
    remaining = if consumed == amount, do: rest, else: [{lot, amount - consumed} | rest]
    take_credit_chunks(remaining, needed - consumed, [{lot, consumed} | used])
  end

  defp take_credit_chunks([], _needed, used), do: {Enum.reverse(used), []}

  defp classify_historical_payments!(payments, group) do
    disposition =
      cond do
        group.refunded_cents > 0 -> :refunded_cents
        group.retained_cents > 0 -> :retained_cents
        group.cash_converted_to_credit_cents > 0 -> :converted_to_credit_cents
        true -> nil
      end

    if disposition do
      Enum.reduce(payments, Map.fetch!(group_to_map(group), disposition), fn payment, remaining ->
        amount = min(payment.recorded_cents, remaining)
        payment |> CashPayment.changeset(%{disposition => amount}) |> Repo.update!()
        remaining - amount
      end)
    end

    if disposition == :converted_to_credit_cents do
      lot =
        Repo.get_by(CreditLot, source_operation_id: historical_cancel_operation(group.group_id))

      if lot, do: create_historical_entitlements!(lot, payments)
    end
  end

  defp group_to_map(group), do: Map.from_struct(group)

  defp historical_cancel_operation(group_id) do
    Repo.all(
      from o in Operation,
        where: o.operation_type in ["cancel_group", "cancel_rooms"],
        order_by: o.id
    )
    |> Enum.find_value(fn operation ->
      if operation.result["status"] == "applied" and operation.result["group_id"] == group_id and
           operation.result["credit_issued_cents"] > 0,
         do: operation.operation_id
    end)
  end

  defp create_historical_entitlements!(lot, payments) do
    Enum.reduce(payments, {0, 0}, fn payment, {running, entitled} ->
      amount = payment.converted_to_credit_cents
      next_running = running + amount
      next_entitled = bonus_value(next_running)
      value = next_entitled - entitled

      if value > 0 and not legacy_payment?(payment) do
        Repo.insert!(
          CreditEntitlement.changeset(%CreditEntitlement{}, %{
            credit_lot_id: lot.id,
            cash_payment_id: payment.id,
            amount_cents: value
          })
        )
      end

      {next_running, next_entitled}
    end)
  end

  defp backfill_credit_allocations!(group, rooms) do
    old =
      Repo.all(
        from a in CreditAllocation,
          where: a.group_reservation_id == ^group.id,
          order_by: a.id,
          preload: [:credit_lot]
      )

    if old != [] and Enum.any?(old, &is_nil(&1.group_room_id)) do
      Enum.each(old, &Repo.delete!/1)
      chunks = Enum.map(old, &{&1.credit_lot, &1.amount_cents})
      allocate_credit_chunks!(rooms, chunks, group.id, nil)
    end
  end

  defp ensure_operation_group_accounting!(operation) do
    if operation.operation_type == "record_cash_payment" and
         operation.result["status"] == "applied" do
      case Repo.get_by(Group, group_id: operation.result["group_id"]) do
        nil -> :ok
        group -> ensure_accounting!(group)
      end
    end
  end

  defp active_rooms(group_id),
    do:
      Repo.all(
        from r in Room,
          where: r.group_reservation_id == ^group_id and r.status == "active",
          order_by: r.position
      )

  defp room_outstanding(room) do
    cash =
      Repo.one(
        from a in CashAllocation,
          where: a.group_room_id == ^room.id,
          select: coalesce(sum(a.amount_cents), 0)
      )

    credit =
      Repo.one(
        from a in CreditAllocation,
          where: a.group_room_id == ^room.id,
          select: coalesce(sum(a.amount_cents), 0)
      )

    max(room.deposit_due_cents - cash - credit, 0)
  end

  defp sync_group!(group, attrs \\ %{}) do
    rooms = active_rooms(group.id)
    lodging = Enum.sum_by(rooms, & &1.lodging_total_cents)
    due = Enum.sum_by(rooms, & &1.deposit_due_cents)
    cash = Enum.sum_by(rooms, fn room -> room_cash(room.id) end)
    credit = Enum.sum_by(rooms, fn room -> room_credit(room.id) end)

    update_group!(
      group,
      Map.merge(
        %{
          lodging_total_cents: lodging,
          deposit_due_cents: due,
          cash_paid_cents: cash,
          credit_paid_cents: credit,
          deposit_paid_cents: cash + credit
        },
        attrs
      )
    )
  end

  defp room_cash(room_id),
    do:
      Repo.one(
        from a in CashAllocation,
          where: a.group_room_id == ^room_id,
          select: coalesce(sum(a.amount_cents), 0)
      )

  defp room_credit(room_id),
    do:
      Repo.one(
        from a in CreditAllocation,
          where: a.group_room_id == ^room_id,
          select: coalesce(sum(a.amount_cents), 0)
      )

  defp held_cash(payment_id),
    do:
      Repo.one(
        from a in CashAllocation,
          where: a.cash_payment_id == ^payment_id,
          select: coalesce(sum(a.amount_cents), 0)
      )

  defp payment_json(payment) do
    statement = %{
      "payment_operation_id" => payment.operation_id,
      "original_group_id" => Repo.get!(Group, payment.group_reservation_id).group_id,
      "recorded_cents" => payment.recorded_cents,
      "held_cents" => held_cash(payment.id),
      "refunded_cents" => payment.refunded_cents,
      "retained_cents" => payment.retained_cents,
      "converted_to_credit_cents" => payment.converted_to_credit_cents,
      "reduced_cents" => payment.reduced_cents,
      "charged_back_cents" => payment.charged_back_cents
    }

    if Repo.exists?(
         from p in PaymentTransferParticipation, where: p.cash_payment_id == ^payment.id
       ) do
      held_by_group =
        Repo.all(
          from a in CashAllocation,
            join: r in Room,
            on: r.id == a.group_room_id,
            join: g in Group,
            on: g.id == r.group_reservation_id,
            where: a.cash_payment_id == ^payment.id,
            group_by: g.group_id,
            order_by: g.group_id,
            select: %{
              "group_id" => g.group_id,
              "amount_cents" => sum(a.amount_cents)
            }
        )

      Map.put(statement, "held_by_group", held_by_group)
    else
      statement
    end
  end

  defp daily_cash_report(_start, date) do
    openings = Map.new(Repo.all(FinanceCashOpening), &{&1.property_id, &1.opening_held_cents})
    rows = Repo.all(from m in FinanceCashMovement, where: m.posting_on <= ^date)

    properties =
      (Map.keys(openings) ++ Enum.map(rows, & &1.property_id))
      |> Enum.uniq()
      |> Enum.sort()

    entries =
      Enum.map(properties, fn property_id ->
        property_rows = Enum.filter(rows, &(&1.property_id == property_id))
        prior = Enum.filter(property_rows, &Date.before?(&1.posting_on, date))
        today = Enum.filter(property_rows, &(&1.posting_on == date))
        ordinary_today = Enum.reject(today, & &1.late_adjustment)
        late_today = Enum.filter(today, & &1.late_adjustment)

        opening =
          Map.get(openings, property_id, 0) + cash_delta(sum_fields(prior, @cash_movement_fields))

        movements = sum_fields(ordinary_today, @cash_movement_fields)
        late_movements = sum_fields(late_today, @cash_movement_fields)
        closing = opening + cash_delta(movements) + cash_delta(late_movements)

        {%{
           "property_id" => property_id,
           "opening_held_cents" => opening,
           "movements" => stringify_fields(movements),
           "closing_held_cents" => closing
         }, %{"property_id" => property_id, "movements" => stringify_fields(late_movements)},
         late_movements}
      end)

    cash =
      entries
      |> Enum.reject(fn {entry, _late_entry, late_movements} ->
        entry["opening_held_cents"] == 0 and entry["closing_held_cents"] == 0 and
          zero_movements?(entry["movements"]) and zero_movements?(late_movements)
      end)
      |> Enum.map(&elem(&1, 0))

    late_cash =
      entries
      |> Enum.reject(fn {_entry, _late_entry, late_movements} ->
        zero_movements?(late_movements)
      end)
      |> Enum.map(&elem(&1, 1))

    {cash, late_cash}
  end

  defp daily_credit_report(start, date) do
    rows = Repo.all(from m in FinanceCreditMovement, where: m.posting_on <= ^date)
    prior = Enum.filter(rows, &Date.before?(&1.posting_on, date))
    today = Enum.filter(rows, &(&1.posting_on == date))
    ordinary_today = Enum.reject(today, & &1.late_adjustment)
    late_today = Enum.filter(today, & &1.late_adjustment)

    opening =
      start.opening_credit_liability_cents +
        credit_delta(sum_fields(prior, @credit_movement_fields))

    movements = sum_fields(ordinary_today, @credit_movement_fields)
    late_movements = sum_fields(late_today, @credit_movement_fields)

    {%{
       "opening_liability_cents" => opening,
       "movements" => stringify_fields(movements),
       "closing_liability_cents" =>
         opening + credit_delta(movements) + credit_delta(late_movements)
     }, late_movements}
  end

  defp sum_fields(rows, fields) do
    Map.new(fields, fn field -> {field, Enum.sum_by(rows, &Map.fetch!(&1, field))} end)
  end

  defp stringify_fields(fields),
    do: Map.new(fields, fn {field, amount} -> {Atom.to_string(field), amount} end)

  defp zero_movements?(movements),
    do: Enum.all?(movements, fn {_field, amount} -> amount == 0 end)

  defp cash_delta(movements) do
    movements.received_cents + movements.transferred_in_cents - movements.transferred_out_cents -
      movements.refunded_cents - movements.retained_cents -
      movements.converted_to_credit_cents - movements.reduced_cents -
      movements.charged_back_cents
  end

  defp credit_delta(movements) do
    movements.issued_cents - movements.expired_cents - movements.consumed_cents -
      movements.revoked_cents - movements.absorbed_cents
  end

  defp opening_cash_by_property do
    Repo.all(
      from a in CashAllocation,
        join: r in Room,
        on: r.id == a.group_room_id,
        join: g in Group,
        on: g.id == r.group_reservation_id,
        group_by: g.property_id,
        select: {g.property_id, sum(a.amount_cents)}
    )
  end

  defp current_credit_liability(on) do
    available =
      Repo.one(
        from l in CreditLot,
          where: l.remaining_cents > 0 and l.expires_on >= ^on,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    allocated = Repo.one(from a in CreditAllocation, select: coalesce(sum(a.amount_cents), 0))
    available + allocated
  end

  defp record_cash_movement(op, property_id, amounts) do
    with %FinanceReportingStart{} = start <- Repo.one(from s in FinanceReportingStart, limit: 1),
         true <- Enum.any?(amounts, fn {_field, amount} -> amount != 0 end) do
      {posting_on, late_adjustment} = reporting_posting(op, start)

      attrs =
        amounts
        |> Map.merge(%{
          operation_id: op["operation_id"],
          posting_on: posting_on,
          late_adjustment: late_adjustment,
          property_id: property_id
        })

      Repo.insert!(FinanceCashMovement.changeset(%FinanceCashMovement{}, attrs))
    else
      _ -> :ok
    end
  end

  defp record_credit_movement(op, amounts) when is_map(op) do
    case Repo.one(from s in FinanceReportingStart, limit: 1) do
      %FinanceReportingStart{} = start ->
        {posting_on, late_adjustment} = reporting_posting(op, start)

        record_credit_movement(
          op["operation_id"],
          posting_on,
          late_adjustment,
          amounts
        )

      nil ->
        :ok
    end
  end

  defp record_credit_movement(operation_id, intended_on, amounts) do
    {posting_on, late_adjustment} = close_adjusted_posting(intended_on)
    record_credit_movement(operation_id, posting_on, late_adjustment, amounts)
  end

  defp record_credit_movement(operation_id, posting_on, late_adjustment, amounts) do
    with %FinanceReportingStart{starts_on: starts_on} <-
           Repo.one(from s in FinanceReportingStart, limit: 1),
         false <- Date.before?(posting_on, starts_on),
         true <- Enum.any?(amounts, fn {_field, amount} -> amount != 0 end) do
      attrs =
        Map.merge(amounts, %{
          operation_id: operation_id,
          posting_on: posting_on,
          late_adjustment: late_adjustment
        })

      Repo.insert!(FinanceCreditMovement.changeset(%FinanceCreditMovement{}, attrs))
    else
      _ -> :ok
    end
  end

  defp record_expiry_adjustment(op, expires_on, amount) when amount != 0 do
    case Repo.one(from s in FinanceReportingStart, limit: 1) do
      %FinanceReportingStart{} ->
        posting_on = natural_reporting_date(op)
        expiry_on = Date.add(expires_on, 1)
        intended_on = max_date(expiry_on, posting_on)
        {movement_on, late_adjustment} = close_adjusted_posting(intended_on)

        record_credit_movement(op["operation_id"], movement_on, late_adjustment, %{
          expired_cents: amount
        })

      nil ->
        :ok
    end
  end

  defp record_expiry_adjustment(_op, _expires_on, 0), do: :ok

  defp natural_reporting_date(op) do
    case Repo.one(from s in FinanceReportingStart, limit: 1) do
      %FinanceReportingStart{starts_on: starts_on} -> max_date(operation_date(op), starts_on)
      nil -> operation_date(op)
    end
  end

  defp reporting_posting(op, start) do
    op |> operation_date() |> max_date(start.starts_on) |> close_adjusted_posting()
  end

  defp close_adjusted_posting(intended_on) do
    case latest_finance_close() do
      %FinancePeriodClose{period_end_on: period_end_on} ->
        first_open_on = Date.add(period_end_on, 1)
        posting_on = max_date(intended_on, first_open_on)
        {posting_on, Date.after?(posting_on, intended_on)}

      nil ->
        {intended_on, false}
    end
  end

  defp latest_finance_close do
    Repo.one(from c in FinancePeriodClose, order_by: [desc: c.period_end_on], limit: 1)
  end

  defp operation_date(%{"occurred_on" => occurred_on}) do
    {:ok, date} = Date.from_iso8601(occurred_on)
    date
  end

  defp max_date(left, right), do: if(Date.before?(left, right), do: right, else: left)

  defp settlement_amounts(amount, true, "cash"), do: {amount, 0, 0}
  defp settlement_amounts(amount, true, "hotel_credit"), do: {0, 0, amount}
  defp settlement_amounts(amount, false, _method), do: {0, amount, 0}
  defp bonus_value(principal), do: principal + div(principal * 10 + 50, 100)

  defp legacy_payment?(payment) do
    not Repo.exists?(from o in Operation, where: o.operation_id == ^payment.operation_id)
  end

  defp available_lots(guest_id, on) do
    Repo.all(
      from l in CreditLot,
        where:
          l.guest_id == ^guest_id and l.remaining_cents > 0 and l.issued_on <= ^on and
            l.expires_on >= ^on,
        order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
    )
  end

  defp update_group!(group, attrs) do
    group |> Group.changeset(Map.put(attrs, :revision, group.revision + 1)) |> Repo.update!()
  end

  defp room_amounts(room, nights, rate_plan) do
    lodging = room["nightly_rate_cents"] * nights
    due = if rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging

    %Room{
      room_id: room["room_id"],
      nightly_rate_cents: room["nightly_rate_cents"],
      lodging_total_cents: lodging,
      deposit_due_cents: due
    }
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn
        %{"room_id" => id, "nightly_rate_cents" => rate} ->
          is_binary(id) and id != "" and is_integer(rate) and rate > 0

        _ ->
          false
      end)

    if valid and Enum.uniq_by(rooms, &Map.get(&1, "room_id")) == rooms,
      do: {:ok, rooms},
      else: {:error, "invalid_rooms"}
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}
  defp validate_identifier(value) when is_binary(value) and value != "", do: :ok
  defp validate_identifier(_value), do: {:error, "invalid_operation"}
  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp validate_group_is_new(group_id) do
    if Repo.exists?(from g in Group, where: g.group_id == ^group_id),
      do: {:error, "group_already_exists"},
      else: :ok
  end

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}
  defp policy_version("advance_purchase", _), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on),
    do: if(Date.before?(booked_on, ~D[2027-01-01]), do: "flex-14", else: "flex-30")

  defp refundable_until(%Group{policy_version: "flex-14", arrival_on: arrival}),
    do: Date.add(arrival, -14)

  defp refundable_until(%Group{policy_version: "flex-30", arrival_on: arrival}),
    do: Date.add(arrival, -30)

  defp refundable_until(%Group{}), do: nil

  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      deadline -> not Date.after?(occurred_on, deadline)
    end
  end

  defp format_date(nil), do: nil
  defp format_date(date), do: Date.to_iso8601(date)

  defp parse_date(value, code) when is_binary(value),
    do:
      case(Date.from_iso8601(value),
        do: (
          {:ok, date} -> {:ok, date}
          _ -> {:error, code}
        )
      )

  defp parse_date(_value, code), do: {:error, code}

  defp outstanding(%Group{status: "active"} = group),
    do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  defp outstanding(%Group{}), do: 0
  defp reject(code, fields \\ %{}), do: {:error, Map.put(fields, "code", code)}
end
