defmodule GroupStay.Operations do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.{
    CashPayment,
    CashPaymentDisposition,
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    Finance,
    Group,
    Operation,
    Repo,
    Room,
    RoomFundingAllocation
  }

  @max_sqlite_integer 9_223_372_036_854_775_807
  @policy_cutoff ~D[2027-01-01]
  @rate_plans ["flexible", "advance_purchase"]

  def process_batch(operations), do: Enum.map(operations, &process_operation/1)

  # Called by the room-accounting migration after its schema changes are flushed.
  def backfill_room_accounting, do: initialize_all_accounting()

  def get_group(group_id) when is_binary(group_id) do
    {:ok, group} =
      Repo.transaction(fn ->
        case Repo.get_by(Group, group_id: group_id) do
          nil -> nil
          group -> preload_group(group)
        end
      end)

    group
  end

  def get_group(_group_id), do: nil

  def get_operation_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil -> nil
      operation -> operation.result
    end
  end

  def get_operation_result(_operation_id), do: nil

  def get_payment(operation_id) when is_binary(operation_id) do
    {:ok, result} =
      Repo.transaction(fn ->
        case Repo.get_by(Operation, operation_id: operation_id) do
          nil ->
            nil

          operation ->
            if applied_cash_operation?(operation) do
              group = Repo.get_by!(Group, group_id: operation.result["group_id"])
              payment = Repo.get_by!(CashPayment, operation_id: operation_id)

              statement = %{
                payment_operation_id: operation_id,
                original_group_id: group.group_id,
                recorded_cents: payment.recorded_cents,
                held_cents: held_cash(operation_id),
                refunded_cents: payment.refunded_cents,
                retained_cents: payment.retained_cents,
                converted_to_credit_cents: payment.converted_cents,
                reduced_cents: payment.reduced_cents,
                charged_back_cents: payment.charged_back_cents
              }

              if payment.participated_in_transfer do
                Map.put(statement, :held_by_group, held_cash_by_group(operation_id))
              else
                statement
              end
            else
              :not_reconcilable
            end
        end
      end)

    result
  end

  def get_payment(_operation_id), do: nil

  def present_group(%Group{} = group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: group.booked_on,
      arrival_on: group.arrival_on,
      departure_on: group.departure_on,
      rate_plan: group.rate_plan,
      policy_version: policy_version(group),
      refundable_until: refundable_until(group),
      status: group.status,
      rooms: Enum.map(group.rooms, &present_room/1),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.deposit_paid_cents - group.credit_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: outstanding(group)
    }
  end

  def read_date(params) do
    result =
      case Map.fetch(params, "on") do
        :error -> {:ok, Date.utc_today()}
        {:ok, value} -> parse_read_date(value)
      end

    case result do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  def guest_credit(guest_id, on) do
    lots = available_lots(guest_id, on)

    %{
      guest_id: guest_id,
      available_cents: Enum.reduce(lots, 0, &(&1.remaining_cents + &2)),
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

  def ledger(on) do
    {:ok, totals} =
      Repo.transaction(fn ->
        cash_held = allocation_sum("cash")

        historical =
          Repo.all(
            from(g in Group,
              select: {g.refunded_cents, g.retained_cents, g.cash_converted_to_credit_cents}
            )
          )
          |> Enum.reduce({0, 0, 0}, fn {refunded, retained, converted}, {r, t, c} ->
            {r + refunded, t + retained, c + converted}
          end)

        {cash_refunded, cash_retained, cash_converted} = historical

        {cash_reduced, cash_charged_back} =
          Repo.all(from(p in CashPayment, select: {p.reduced_cents, p.charged_back_cents}))
          |> Enum.reduce({0, 0}, fn {reduced, charged}, {r, c} ->
            {r + reduced, c + charged}
          end)

        available_credit =
          Repo.all(from(l in CreditLot, where: l.expires_on >= ^on, select: l.remaining_cents))
          |> Enum.sum()

        applied_by_lot =
          Repo.all(
            from(a in RoomFundingAllocation,
              where: a.kind == "credit",
              group_by: a.credit_lot_id,
              select: {a.credit_lot_id, sum(a.amount_cents)}
            )
          )
          |> Map.new()

        applied_credit = applied_by_lot |> Map.values() |> Enum.sum()

        credit_shortfall =
          Repo.all(from(l in CreditLot, select: {l.id, l.unrecovered_clawback_cents}))
          |> Enum.reduce(0, fn {lot_id, clawback}, total ->
            total + min(clawback, Map.get(applied_by_lot, lot_id, 0))
          end)

        %{
          cash_held_cents: cash_held,
          cash_refunded_cents: cash_refunded,
          cash_retained_cents: cash_retained,
          cash_converted_to_credit_cents: cash_converted,
          cash_reduced_cents: cash_reduced,
          cash_charged_back_cents: cash_charged_back,
          credit_liability_cents: available_credit + applied_credit,
          credit_shortfall_cents: credit_shortfall
        }
      end)

    totals
  end

  defp process_operation(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")

    if valid_identifier?(operation_id) do
      Repo.transaction(fn -> process_idempotently(operation, operation_id) end, mode: :immediate)
      |> transaction_result()
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp process_operation(_operation), do: rejected(nil, "invalid_operation")

  defp process_idempotently(operation, operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil ->
        result = execute_operation(operation, operation_id)
        stored_result = result |> Jason.encode!() |> Jason.decode!()

        %Operation{}
        |> Operation.changeset(%{
          operation_id: operation_id,
          type: submitted_type(operation),
          submission: operation,
          result: stored_result
        })
        |> Repo.insert!()

        stored_result

      stored ->
        if stored.submission === operation do
          stored.result
        else
          rejected(operation_id, "operation_id_conflict")
        end
    end
  end

  defp execute_operation(operation, operation_id) do
    case Map.get(operation, "type") do
      "start_finance_reporting" ->
        process_type("start_finance_reporting", operation, operation_id, nil)

      "close_finance_period" ->
        process_type("close_finance_period", operation, operation_id, nil)

      type when is_binary(type) ->
        case parse_common_date(operation) do
          {:ok, occurred_on} -> process_type(type, operation, operation_id, occurred_on)
          _ -> rejected(operation_id, "invalid_operation")
        end

      _ ->
        rejected(operation_id, "invalid_operation")
    end
  end

  defp process_type("open_group", operation, operation_id, occurred_on) do
    required = [
      "group_id",
      "guest_id",
      "property_id",
      "arrival_on",
      "departure_on",
      "rate_plan",
      "rooms"
    ]

    if Enum.all?(required, &Map.has_key?(operation, &1)) and
         valid_identifier?(operation["group_id"]) and valid_identifier?(operation["guest_id"]) and
         valid_identifier?(operation["property_id"]) do
      open_group(operation, operation_id, occurred_on)
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp process_type("start_finance_reporting", operation, operation_id, _occurred_on) do
    case parse_date(operation["starts_on"]) do
      {:ok, starts_on} ->
        case Finance.start(starts_on) do
          :ok -> applied(operation_id, starts_on: starts_on)
          {:error, :already_started} -> rejected(operation_id, "reporting_already_started")
        end

      _ ->
        rejected(operation_id, "invalid_reporting_date")
    end
  end

  defp process_type("close_finance_period", operation, operation_id, _occurred_on) do
    case parse_date(operation["period_end_on"]) do
      {:ok, period_end_on} ->
        case Finance.close(period_end_on) do
          :ok -> applied(operation_id, period_end_on: period_end_on)
          {:error, :invalid_period} -> rejected(operation_id, "invalid_period")
        end

      _ ->
        rejected(operation_id, "invalid_period")
    end
  end

  defp process_type(type, operation, operation_id, occurred_on)
       when type in [
              "record_cash_payment",
              "apply_hotel_credit",
              "reschedule_group",
              "cancel_group",
              "cancel_rooms"
            ] do
    required =
      case type do
        type when type in ["record_cash_payment", "apply_hotel_credit"] ->
          ["group_id", "amount_cents"]

        "reschedule_group" ->
          ["group_id", "new_arrival_on"]

        "cancel_rooms" ->
          ["group_id", "room_ids"]

        "cancel_group" ->
          ["group_id"]
      end

    if Enum.all?(required, &Map.has_key?(operation, &1)) and
         valid_identifier?(operation["group_id"]) do
      update_group(type, operation, operation_id, occurred_on)
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp process_type("transfer_deposit", operation, operation_id, occurred_on) do
    required = ["source_group_id", "destination_group_id", "amount_cents"]

    if Enum.all?(required, &Map.has_key?(operation, &1)) and
         valid_identifier?(operation["source_group_id"]) and
         valid_identifier?(operation["destination_group_id"]) do
      transfer_deposit(operation, operation_id, occurred_on)
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp process_type("reduce_cash_payment", operation, operation_id, occurred_on) do
    if Map.has_key?(operation, "payment_operation_id") and Map.has_key?(operation, "amount_cents") and
         valid_identifier?(operation["payment_operation_id"]) do
      reduce_cash_payment(operation, operation_id, occurred_on)
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp process_type("charge_back_payment", operation, operation_id, occurred_on) do
    if Map.has_key?(operation, "payment_operation_id") and
         valid_identifier?(operation["payment_operation_id"]) do
      charge_back_payment(operation, operation_id, occurred_on)
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp process_type(_type, _operation, operation_id, _occurred_on) do
    rejected(operation_id, "invalid_operation")
  end

  defp open_group(operation, operation_id, occurred_on) do
    group_id = operation["group_id"]

    if Repo.get_by(Group, group_id: group_id) do
      rejected(operation_id, "group_already_exists", group_id: group_id)
    else
      with {:ok, arrival_on, departure_on, nights} <- validate_stay(operation),
           {:ok, rooms} <- validate_rooms(operation["rooms"]),
           {:ok, rate_plan} <- validate_rate_plan(operation["rate_plan"]),
           {:ok, rooms, lodging_total, deposit_due} <-
             calculate_totals(rooms, nights, rate_plan) do
        attrs = %{
          group_id: group_id,
          guest_id: operation["guest_id"],
          property_id: operation["property_id"],
          booked_on: occurred_on,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: rate_plan,
          policy_version: policy_version(rate_plan, occurred_on),
          status: "active",
          revision: 1,
          lodging_total_cents: lodging_total,
          deposit_due_cents: deposit_due,
          accounting_initialized: true,
          rooms: rooms
        }

        case %Group{} |> Group.create_changeset(attrs) |> Repo.insert() do
          {:ok, _group} ->
            applied(operation_id,
              group_id: group_id,
              deposit_due_cents: deposit_due,
              revision: 1
            )

          {:error, changeset} ->
            if Keyword.has_key?(changeset.errors, :group_id) do
              rejected(operation_id, "group_already_exists", group_id: group_id)
            else
              rejected(operation_id, "invalid_operation")
            end
        end
      else
        {:error, code} -> rejected(operation_id, code, group_id: group_id)
      end
    end
  end

  defp update_group(type, operation, operation_id, occurred_on) do
    group_id = operation["group_id"]

    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        rejected(operation_id, "group_not_found", group_id: group_id)

      group ->
        with :ok <- validate_revision(group, operation, operation_id),
             :ok <- validate_active(group, operation_id) do
          perform_update(type, group, operation, operation_id, occurred_on)
        else
          {:rejected, result} -> result
        end
    end
  end

  defp perform_update("record_cash_payment", group, operation, operation_id, occurred_on) do
    amount = operation["amount_cents"]

    cond do
      not valid_amount?(amount) ->
        rejected(operation_id, "invalid_amount", group_id: group.group_id)

      amount > outstanding(group) ->
        rejected(operation_id, "payment_exceeds_outstanding", group_id: group.group_id)

      true ->
        paid = group.deposit_paid_cents + amount

        case persist_group_update(group, [deposit_paid_cents: paid], operation_id, operation) do
          {:ok, revision} ->
            %CashPayment{}
            |> CashPayment.changeset(%{
              operation_id: operation_id,
              group_id: group.id,
              recorded_cents: amount
            })
            |> Repo.insert!()

            allocate_funding(group, "cash", operation_id, nil, amount)

            Finance.record(operation_id, occurred_on, [
              %{kind: "received", property_id: group.property_id, amount_cents: amount}
            ])

            applied(operation_id,
              group_id: group.group_id,
              amount_cents: amount,
              outstanding_deposit_cents: group.deposit_due_cents - paid,
              revision: revision
            )

          {:error, result} ->
            result
        end
    end
  end

  defp perform_update("apply_hotel_credit", group, operation, operation_id, occurred_on) do
    apply_hotel_credit(group, operation, operation_id, occurred_on)
  end

  defp perform_update("reschedule_group", group, operation, operation_id, occurred_on) do
    case prepare_reschedule(group, operation, occurred_on) do
      {:ok, updates, fields} -> apply_update(group, updates, operation_id, fields, operation)
      {:error, code} -> rejected(operation_id, code, group_id: group.group_id)
    end
  end

  defp perform_update("cancel_group", group, operation, operation_id, occurred_on) do
    rooms =
      Repo.all(
        from(r in Room,
          where: r.group_id == ^group.id and r.status == "active",
          order_by: r.position
        )
      )

    settle_rooms(group, rooms, operation, operation_id, occurred_on, false)
  end

  defp perform_update("cancel_rooms", group, operation, operation_id, occurred_on) do
    active_rooms =
      Repo.all(
        from(r in Room,
          where: r.group_id == ^group.id and r.status == "active",
          order_by: r.position
        )
      )

    room_ids = operation["room_ids"]

    if is_list(room_ids) and room_ids != [] and Enum.all?(room_ids, &valid_identifier?/1) and
         Enum.uniq(room_ids) == room_ids do
      selected = Enum.filter(active_rooms, &(&1.room_id in room_ids))

      if length(selected) == length(room_ids) do
        settle_rooms(group, selected, operation, operation_id, occurred_on, true)
      else
        rejected(operation_id, "invalid_rooms", group_id: group.group_id)
      end
    else
      rejected(operation_id, "invalid_rooms", group_id: group.group_id)
    end
  end

  defp apply_hotel_credit(group, operation, operation_id, occurred_on) do
    amount = operation["amount_cents"]

    cond do
      not valid_amount?(amount) ->
        rejected(operation_id, "invalid_amount", group_id: group.group_id)

      amount > outstanding(group) ->
        rejected(operation_id, "payment_exceeds_outstanding", group_id: group.group_id)

      true ->
        lots = available_lots(group.guest_id, occurred_on)

        if Enum.reduce(lots, 0, &(&1.remaining_cents + &2)) < amount do
          rejected(operation_id, "insufficient_credit", group_id: group.group_id)
        else
          paid = group.deposit_paid_cents + amount

          case persist_group_update(
                 group,
                 [deposit_paid_cents: paid, credit_paid_cents: group.credit_paid_cents + amount],
                 operation_id,
                 operation
               ) do
            {:ok, revision} ->
              events = consume_credit_lots(lots, group, operation_id, amount)
              Finance.record(operation_id, occurred_on, events)

              applied(operation_id,
                group_id: group.group_id,
                amount_cents: amount,
                outstanding_deposit_cents: group.deposit_due_cents - paid,
                revision: revision
              )

            {:error, result} ->
              result
          end
        end
    end
  end

  defp settle_rooms(group, rooms, operation, operation_id, occurred_on, partial?) do
    method = Map.get(operation, "refund_method", "cash")
    refundable = refundable?(group, occurred_on)

    cond do
      method not in ["cash", "hotel_credit"] ->
        rejected(operation_id, "refund_method_not_available", group_id: group.group_id)

      method == "hotel_credit" and not refundable ->
        rejected(operation_id, "refund_method_not_available", group_id: group.group_id)

      true ->
        room_db_ids = Enum.map(rooms, & &1.id)

        allocations =
          Repo.all(
            from(a in RoomFundingAllocation,
              where: a.room_id in ^room_db_ids,
              order_by: a.id
            )
          )

        cash_allocations = Enum.filter(allocations, &(&1.kind == "cash"))
        credit_allocations = Enum.filter(allocations, &(&1.kind == "credit"))
        cash = Enum.reduce(cash_allocations, 0, &(&1.amount_cents + &2))
        refunded = if refundable and method == "cash", do: cash, else: 0
        retained = if refundable, do: 0, else: cash
        converted = if refundable and method == "hotel_credit", do: cash, else: 0
        issued = converted + round_percentage(converted, 10)

        disposition =
          cond do
            refunded > 0 -> :refunded_cents
            retained > 0 -> :retained_cents
            converted > 0 -> :converted_cents
            true -> nil
          end

        if disposition,
          do: update_payment_dispositions(cash_allocations, group.id, disposition)

        issued_event =
          if issued > 0 do
            lot =
              %CreditLot{}
              |> CreditLot.changeset(%{
                guest_id: group.guest_id,
                source_operation_id: operation_id,
                remaining_cents: issued,
                expires_on: Date.add(occurred_on, 365)
              })
              |> Repo.insert!()

            create_entitlements(lot, cash_allocations)

            %{
              kind: "issued",
              credit_lot_id: lot.id,
              expires_on: lot.expires_on,
              amount_cents: issued
            }
          end

        credit_events = settle_credit_allocations(credit_allocations, refundable, occurred_on)
        Repo.delete_all(from(a in RoomFundingAllocation, where: a.room_id in ^room_db_ids))

        Repo.update_all(from(r in Room, where: r.id in ^room_db_ids), set: [status: "cancelled"])

        totals = active_totals(group.id)
        status = if totals.active_room_count == 0, do: "cancelled", else: "active"

        updates = [
          status: status,
          lodging_total_cents: totals.lodging,
          deposit_due_cents: totals.due,
          deposit_paid_cents: totals.paid,
          credit_paid_cents: totals.credit,
          refunded_cents: group.refunded_cents + refunded,
          retained_cents: group.retained_cents + retained,
          cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted
        ]

        case persist_group_update(group, updates, operation_id, operation) do
          {:ok, revision} ->
            cash_events =
              [
                %{kind: "refunded", property_id: group.property_id, amount_cents: refunded},
                %{kind: "retained", property_id: group.property_id, amount_cents: retained},
                %{
                  kind: "converted_to_credit",
                  property_id: group.property_id,
                  amount_cents: converted
                }
              ]

            Finance.record(
              operation_id,
              occurred_on,
              cash_events ++ List.wrap(issued_event) ++ credit_events
            )

            fields = [
              group_id: group.group_id,
              refunded_cents: refunded,
              retained_cents: retained,
              credit_issued_cents: issued,
              revision: revision
            ]

            fields =
              if partial? do
                Keyword.put(fields, :cancelled_room_ids, Enum.map(rooms, & &1.room_id))
              else
                fields
              end

            applied(operation_id, fields)

          {:error, result} ->
            result
        end
    end
  end

  defp transfer_deposit(operation, operation_id, occurred_on) do
    source_group_id = operation["source_group_id"]
    destination_group_id = operation["destination_group_id"]

    case Repo.get_by(Group, group_id: source_group_id) do
      nil ->
        rejected(operation_id, "group_not_found", group_id: source_group_id)

      source ->
        case Repo.get_by(Group, group_id: destination_group_id) do
          nil ->
            rejected(operation_id, "group_not_found", group_id: destination_group_id)

          destination ->
            with :ok <- validate_revision(source, operation, operation_id, "expected_revision"),
                 :ok <-
                   validate_revision(
                     destination,
                     operation,
                     operation_id,
                     "destination_expected_revision"
                   ) do
              perform_transfer(source, destination, operation, operation_id, occurred_on)
            else
              {:rejected, result} -> result
            end
        end
    end
  end

  defp perform_transfer(source, destination, operation, operation_id, occurred_on) do
    amount = operation["amount_cents"]
    source_totals = active_totals(source.id)
    destination_totals = active_totals(destination.id)

    cond do
      source.id == destination.id or source.guest_id != destination.guest_id ->
        rejected(operation_id, "invalid_transfer")

      source.status != "active" ->
        rejected(operation_id, "group_not_active", group_id: source.group_id)

      destination.status != "active" ->
        rejected(operation_id, "group_not_active", group_id: destination.group_id)

      not valid_amount?(amount) ->
        rejected(operation_id, "invalid_amount")

      amount > source_totals.paid ->
        rejected(operation_id, "transfer_exceeds_held_funding")

      amount > destination_totals.due - destination_totals.paid ->
        rejected(operation_id, "transfer_exceeds_outstanding")

      true ->
        chunks = draw_allocations(source.id, amount)
        allocate_chunks(destination, chunks)
        mark_transferred_payments(chunks)

        states = refresh_group_funding([source.id, destination.id])
        source_state = Map.fetch!(states, source.id)
        destination_state = Map.fetch!(states, destination.id)

        cash =
          chunks
          |> Enum.filter(&(&1.kind == "cash"))
          |> Enum.reduce(0, &(&1.amount_cents + &2))

        Finance.record(operation_id, occurred_on, [
          %{kind: "transferred_out", property_id: source.property_id, amount_cents: cash},
          %{kind: "transferred_in", property_id: destination.property_id, amount_cents: cash}
        ])

        applied(operation_id,
          source_group_id: source.group_id,
          destination_group_id: destination.group_id,
          amount_cents: amount,
          source_outstanding_deposit_cents: source_state.totals.due - source_state.totals.paid,
          destination_outstanding_deposit_cents:
            destination_state.totals.due - destination_state.totals.paid,
          source_revision: source_state.revision,
          destination_revision: destination_state.revision
        )
    end
  end

  defp reduce_cash_payment(operation, operation_id, occurred_on) do
    target_id = operation["payment_operation_id"]

    case payment_target(target_id) do
      :not_found ->
        rejected(operation_id, "operation_not_found")

      :not_payment ->
        rejected(operation_id, "payment_not_reducible")

      {:ok, payment, group} ->
        with :ok <- validate_revision(group, operation, operation_id) do
          held = held_cash(target_id)
          amount = operation["amount_cents"]

          cond do
            held == 0 ->
              rejected(operation_id, "payment_not_reducible", group_id: group.group_id)

            not valid_amount?(amount) ->
              rejected(operation_id, "invalid_amount", group_id: group.group_id)

            amount > held ->
              rejected(operation_id, "reduction_exceeds_held_cash", group_id: group.group_id)

            true ->
              removed_by_group = remove_cash_allocations(target_id, amount)

              Repo.update_all(from(p in CashPayment, where: p.id == ^payment.id),
                set: [reduced_cents: payment.reduced_cents + amount]
              )

              states = refresh_group_funding([group.id | Map.keys(removed_by_group)])
              state = Map.fetch!(states, group.id)

              events = cash_events_by_group(removed_by_group, "reduced")
              Finance.record(operation_id, occurred_on, events)

              applied(operation_id,
                payment_operation_id: target_id,
                group_id: group.group_id,
                amount_cents: amount,
                outstanding_deposit_cents: state.totals.due - state.totals.paid,
                revision: state.revision
              )
          end
        else
          {:rejected, result} -> result
        end
    end
  end

  defp charge_back_payment(operation, operation_id, occurred_on) do
    target_id = operation["payment_operation_id"]

    case payment_target(target_id) do
      :not_found ->
        rejected(operation_id, "operation_not_found")

      :not_payment ->
        rejected(operation_id, "payment_not_chargeable")

      {:ok, payment, group} ->
        with :ok <- validate_revision(group, operation, operation_id) do
          if payment.charged_back_cents > 0 or payment.recorded_cents == payment.reduced_cents do
            rejected(operation_id, "payment_not_chargeable", group_id: group.group_id)
          else
            held = held_cash(target_id)
            removed_by_group = remove_cash_allocations(target_id, held)
            dispositions = payment_dispositions(payment.id)
            disposition_adjustments = disposition_group_adjustments(dispositions)
            credit_events = revoke_credit_entitlements(target_id, occurred_on)

            charged = payment.recorded_cents - payment.reduced_cents

            Repo.update_all(from(p in CashPayment, where: p.id == ^payment.id),
              set: [
                refunded_cents: 0,
                retained_cents: 0,
                converted_cents: 0,
                charged_back_cents: charged
              ]
            )

            Repo.delete_all(
              from(d in CashPaymentDisposition, where: d.cash_payment_id == ^payment.id)
            )

            group_ids =
              [group.id | Map.keys(removed_by_group) ++ Map.keys(disposition_adjustments)]

            states = refresh_group_funding(group_ids, disposition_adjustments)
            state = Map.fetch!(states, group.id)

            held_events = cash_events_by_group(removed_by_group, "charged_back")
            disposition_events = chargeback_disposition_events(dispositions)

            Finance.record(
              operation_id,
              occurred_on,
              held_events ++ disposition_events ++ credit_events
            )

            applied(operation_id,
              payment_operation_id: target_id,
              group_id: group.group_id,
              charged_back_cents: charged,
              outstanding_deposit_cents:
                if(group.status == "active", do: state.totals.due - state.totals.paid, else: 0),
              revision: state.revision
            )
          end
        else
          {:rejected, result} -> result
        end
    end
  end

  defp payment_target(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil ->
        :not_found

      operation ->
        if applied_cash_operation?(operation) do
          group = Repo.get_by!(Group, group_id: operation.result["group_id"])
          {:ok, Repo.get_by!(CashPayment, operation_id: operation_id), group}
        else
          :not_payment
        end
    end
  end

  defp initialize_all_accounting do
    Repo.all(from(g in Group, where: g.accounting_initialized == false))
    |> Enum.each(&initialize_accounting/1)
  end

  defp initialize_accounting(%Group{accounting_initialized: true} = group), do: group

  defp initialize_accounting(%Group{} = group) do
    group = Repo.preload(group, :rooms)

    funding_operations =
      Repo.all(
        from(o in Operation,
          where: o.type in ["record_cash_payment", "apply_hotel_credit"],
          order_by: o.id
        )
      )
      |> Enum.filter(fn operation ->
        operation.result["status"] == "applied" and operation.result["group_id"] == group.group_id
      end)

    cash_operations = Enum.filter(funding_operations, &(&1.type == "record_cash_payment"))
    credit_operations = Enum.filter(funding_operations, &(&1.type == "apply_hotel_credit"))
    durable_cash = Enum.reduce(cash_operations, 0, &(operation_amount(&1) + &2))
    durable_credit = Enum.reduce(credit_operations, 0, &(operation_amount(&1) + &2))
    original_cash = original_cash_total(group)
    legacy_cash = max(original_cash - durable_cash, 0)
    legacy_credit = max(group.credit_paid_cents - durable_credit, 0)

    Enum.each(cash_operations, fn operation ->
      attrs =
        legacy_payment_disposition(group, operation.operation_id, operation_amount(operation))

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert_all(
        "cash_payments",
        [
          Map.merge(attrs, %{
            group_id: group.id,
            operation_id: operation.operation_id,
            inserted_at: now,
            updated_at: now
          })
        ],
        on_conflict: :nothing,
        conflict_target: :operation_id
      )
    end)

    if group.status == "active" do
      if legacy_cash > 0, do: allocate_funding(group, "cash", nil, nil, legacy_cash)

      credit_chunks = legacy_credit_chunks(group)
      {legacy_chunks, credit_chunks} = take_credit_chunks(credit_chunks, legacy_credit)

      Enum.each(legacy_chunks, fn {lot_id, amount} ->
        allocate_funding(group, "credit", nil, lot_id, amount)
      end)

      Enum.reduce(funding_operations, credit_chunks, fn operation, chunks ->
        amount = operation_amount(operation)

        if operation.type == "record_cash_payment" do
          allocate_funding(group, "cash", operation.operation_id, nil, amount)
          chunks
        else
          {operation_chunks, rest} = take_credit_chunks(chunks, amount)

          Enum.each(operation_chunks, fn {lot_id, chunk_amount} ->
            allocate_funding(group, "credit", operation.operation_id, lot_id, chunk_amount)
          end)

          rest
        end
      end)
    else
      Repo.update_all(from(r in Room, where: r.group_id == ^group.id), set: [status: "cancelled"])
      initialize_legacy_entitlements(group, legacy_cash, cash_operations)
    end

    totals = active_totals(group.id)

    Repo.update_all(from(g in Group, where: g.id == ^group.id),
      set: [
        accounting_initialized: true,
        lodging_total_cents: totals.lodging,
        deposit_due_cents: totals.due,
        deposit_paid_cents: totals.paid,
        credit_paid_cents: totals.credit
      ]
    )

    Repo.get!(Group, group.id)
  end

  defp legacy_payment_disposition(group, _operation_id, amount) do
    cond do
      group.status == "active" ->
        %{recorded_cents: amount}

      group.refunded_cents > 0 ->
        %{recorded_cents: amount, refunded_cents: amount}

      group.retained_cents > 0 ->
        %{recorded_cents: amount, retained_cents: amount}

      group.cash_converted_to_credit_cents > 0 ->
        %{recorded_cents: amount, converted_cents: amount}

      true ->
        %{recorded_cents: amount}
    end
  end

  defp initialize_legacy_entitlements(group, legacy_cash, cash_operations) do
    if group.cash_converted_to_credit_cents > 0 do
      cancellation_ids =
        Repo.all(
          from(o in Operation, where: o.type in ["cancel_group", "cancel_rooms"], order_by: o.id)
        )
        |> Enum.filter(fn operation ->
          operation.result["status"] == "applied" and
            operation.result["group_id"] == group.group_id and
            operation.result["credit_issued_cents"] > 0
        end)
        |> Enum.map(& &1.operation_id)

      case Repo.one(
             from(l in CreditLot, where: l.source_operation_id in ^cancellation_ids, limit: 1)
           ) do
        nil ->
          :ok

        lot ->
          contributions =
            [{nil, legacy_cash}] ++
              Enum.map(cash_operations, &{&1.operation_id, operation_amount(&1)})

          create_entitlement_contributions(lot, Enum.filter(contributions, &(elem(&1, 1) > 0)))
      end
    end
  end

  defp legacy_credit_chunks(group) do
    Repo.all(
      from(a in CreditAllocation,
        where: a.group_id == ^group.id,
        order_by: [asc: a.position, asc: a.id],
        select: {a.credit_lot_id, a.amount_cents}
      )
    )
  end

  defp take_credit_chunks(chunks, amount), do: take_credit_chunks(chunks, amount, [])
  defp take_credit_chunks(chunks, 0, taken), do: {Enum.reverse(taken), chunks}
  defp take_credit_chunks([], _amount, taken), do: {Enum.reverse(taken), []}

  defp take_credit_chunks([{lot_id, available} | rest], amount, taken) do
    used = min(available, amount)
    remaining_chunk = available - used
    rest = if remaining_chunk > 0, do: [{lot_id, remaining_chunk} | rest], else: rest
    take_credit_chunks(rest, amount - used, [{lot_id, used} | taken])
  end

  defp original_cash_total(%Group{status: "active"} = group) do
    group.deposit_paid_cents - group.credit_paid_cents
  end

  defp original_cash_total(group) do
    group.refunded_cents + group.retained_cents + group.cash_converted_to_credit_cents
  end

  defp operation_amount(operation) do
    operation.result["amount_cents"] || operation.submission["amount_cents"]
  end

  defp preload_group(group) do
    Repo.preload(group, [rooms: :funding_allocations], force: true)
  end

  defp present_room(room) do
    {cash, credit} =
      Enum.reduce(room.funding_allocations, {0, 0}, fn allocation, {cash, credit} ->
        if allocation.kind == "cash" do
          {cash + allocation.amount_cents, credit}
        else
          {cash, credit + allocation.amount_cents}
        end
      end)

    %{
      room_id: room.room_id,
      nightly_rate_cents: room.nightly_rate_cents,
      status: room.status,
      lodging_total_cents: room.lodging_total_cents,
      deposit_due_cents: room.deposit_due_cents,
      cash_paid_cents: cash,
      credit_paid_cents: credit
    }
  end

  defp allocate_funding(group, kind, operation_id, credit_lot_id, amount) do
    rooms =
      Repo.all(
        from(r in Room,
          where: r.group_id == ^group.id and r.status == "active",
          order_by: r.position
        )
      )

    used =
      Repo.all(
        from(a in RoomFundingAllocation,
          where: a.group_id == ^group.id,
          group_by: a.room_id,
          select: {a.room_id, sum(a.amount_cents)}
        )
      )
      |> Map.new()

    left =
      Enum.reduce_while(rooms, amount, fn room, left ->
        capacity = room.deposit_due_cents - Map.get(used, room.id, 0)
        allocated = min(capacity, left)

        if allocated > 0 do
          %RoomFundingAllocation{}
          |> RoomFundingAllocation.changeset(%{
            room_id: room.id,
            group_id: group.id,
            kind: kind,
            operation_id: operation_id,
            credit_lot_id: credit_lot_id,
            amount_cents: allocated
          })
          |> Repo.insert!()
        end

        if allocated == left, do: {:halt, 0}, else: {:cont, left - allocated}
      end)

    if left != 0, do: raise("funding exceeds active room deposit")
  end

  defp draw_allocations(group_id, amount) do
    allocations =
      Repo.all(
        from(a in RoomFundingAllocation,
          where: a.group_id == ^group_id,
          order_by: [desc: a.id]
        )
      )

    {left, chunks} =
      Enum.reduce_while(allocations, {amount, []}, fn allocation, {left, chunks} ->
        drawn = min(allocation.amount_cents, left)

        if drawn == allocation.amount_cents do
          Repo.delete!(allocation)
        else
          Repo.update_all(from(a in RoomFundingAllocation, where: a.id == ^allocation.id),
            set: [amount_cents: allocation.amount_cents - drawn]
          )
        end

        chunk = %{
          kind: allocation.kind,
          operation_id: allocation.operation_id,
          credit_lot_id: allocation.credit_lot_id,
          amount_cents: drawn
        }

        if drawn == left,
          do: {:halt, {0, [chunk | chunks]}},
          else: {:cont, {left - drawn, [chunk | chunks]}}
      end)

    if left != 0, do: raise("funding allocation underflow")
    Enum.reverse(chunks)
  end

  defp allocate_chunks(group, chunks) do
    Enum.each(chunks, fn chunk ->
      allocate_funding(
        group,
        chunk.kind,
        chunk.operation_id,
        chunk.credit_lot_id,
        chunk.amount_cents
      )
    end)
  end

  defp mark_transferred_payments(chunks) do
    operation_ids =
      chunks
      |> Enum.filter(&(&1.kind == "cash" and not is_nil(&1.operation_id)))
      |> Enum.map(& &1.operation_id)
      |> Enum.uniq()

    if operation_ids != [] do
      Repo.update_all(from(p in CashPayment, where: p.operation_id in ^operation_ids),
        set: [participated_in_transfer: true]
      )
    end
  end

  defp consume_credit_lots(lots, group, operation_id, amount) do
    {_left, events} =
      Enum.reduce_while(lots, {amount, []}, fn lot, {left, events} ->
        consumed = min(lot.remaining_cents, left)

        Repo.update_all(from(l in CreditLot, where: l.id == ^lot.id),
          set: [remaining_cents: lot.remaining_cents - consumed]
        )

        allocate_funding(group, "credit", operation_id, lot.id, consumed)

        event = %{
          kind: "applied",
          credit_lot_id: lot.id,
          expires_on: lot.expires_on,
          amount_cents: consumed
        }

        if consumed == left,
          do: {:halt, {0, [event | events]}},
          else: {:cont, {left - consumed, [event | events]}}
      end)

    Enum.reverse(events)
  end

  defp update_payment_dispositions(allocations, group_id, field) do
    allocations
    |> Enum.reject(&is_nil(&1.operation_id))
    |> Enum.group_by(& &1.operation_id, & &1.amount_cents)
    |> Enum.each(fn {operation_id, amounts} ->
      payment = Repo.get_by!(CashPayment, operation_id: operation_id)
      amount = Enum.sum(amounts)
      value = Map.fetch!(payment, field) + amount
      Repo.update_all(from(p in CashPayment, where: p.id == ^payment.id), set: [{field, value}])

      kind = disposition_kind(field)

      case Repo.get_by(CashPaymentDisposition,
             cash_payment_id: payment.id,
             group_id: group_id,
             kind: kind
           ) do
        nil ->
          %CashPaymentDisposition{}
          |> CashPaymentDisposition.changeset(%{
            cash_payment_id: payment.id,
            group_id: group_id,
            kind: kind,
            amount_cents: amount
          })
          |> Repo.insert!()

        disposition ->
          Repo.update_all(
            from(d in CashPaymentDisposition, where: d.id == ^disposition.id),
            set: [amount_cents: disposition.amount_cents + amount]
          )
      end
    end)
  end

  defp disposition_kind(:refunded_cents), do: "refunded"
  defp disposition_kind(:retained_cents), do: "retained"
  defp disposition_kind(:converted_cents), do: "converted"

  defp create_entitlements(lot, cash_allocations) do
    contributions = ordered_contributions(cash_allocations)
    create_entitlement_contributions(lot, contributions)
  end

  defp ordered_contributions(allocations) do
    {legacy, durable} = Enum.split_with(allocations, &is_nil(&1.operation_id))
    legacy_amount = Enum.reduce(legacy, 0, &(&1.amount_cents + &2))
    legacy = if legacy_amount > 0, do: [{nil, legacy_amount}], else: []

    legacy ++ Enum.map(durable, &{&1.operation_id, &1.amount_cents})
  end

  defp create_entitlement_contributions(lot, contributions) do
    {_running, order, entitlements} =
      Enum.reduce(contributions, {0, [], %{}}, fn {payment_operation_id, principal},
                                                  {running, order, entitlements} ->
        next_running = running + principal

        credit =
          next_running + round_percentage(next_running, 10) - running -
            round_percentage(running, 10)

        order =
          if Map.has_key?(entitlements, payment_operation_id),
            do: order,
            else: order ++ [payment_operation_id]

        entitlements =
          Map.update(
            entitlements,
            payment_operation_id,
            %{principal: principal, credit: credit},
            fn entitlement ->
              %{
                principal: entitlement.principal + principal,
                credit: entitlement.credit + credit
              }
            end
          )

        {next_running, order, entitlements}
      end)

    Enum.each(order, fn payment_operation_id ->
      entitlement = Map.fetch!(entitlements, payment_operation_id)

      %CreditEntitlement{}
      |> CreditEntitlement.changeset(%{
        credit_lot_id: lot.id,
        payment_operation_id: payment_operation_id,
        principal_cents: entitlement.principal,
        credit_cents: entitlement.credit
      })
      |> Repo.insert!()
    end)
  end

  defp settle_credit_allocations(allocations, refundable, occurred_on) do
    if refundable do
      allocations
      |> Enum.group_by(& &1.credit_lot_id, & &1.amount_cents)
      |> Enum.flat_map(fn {lot_id, amounts} ->
        restore_credit(lot_id, Enum.sum(amounts), occurred_on)
      end)
    else
      allocations
      |> Enum.group_by(& &1.credit_lot_id, & &1.amount_cents)
      |> Enum.map(fn {lot_id, amounts} ->
        lot = Repo.get!(CreditLot, lot_id)

        %{
          kind: "consumed",
          credit_lot_id: lot_id,
          expires_on: lot.expires_on,
          amount_cents: Enum.sum(amounts)
        }
      end)
    end
  end

  defp restore_credit(lot_id, amount, occurred_on) do
    lot = Repo.get!(CreditLot, lot_id)
    absorbed = min(lot.unrecovered_clawback_cents, amount)
    excess = amount - absorbed

    remaining =
      if Date.compare(lot.expires_on, occurred_on) in [:eq, :gt] do
        lot.remaining_cents + excess
      else
        lot.remaining_cents
      end

    Repo.update_all(from(l in CreditLot, where: l.id == ^lot.id),
      set: [
        remaining_cents: remaining,
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
      ]
    )

    restored =
      if excess > 0 and Date.compare(lot.expires_on, occurred_on) in [:eq, :gt] do
        [
          %{
            kind: "restored",
            credit_lot_id: lot.id,
            expires_on: lot.expires_on,
            amount_cents: excess
          }
        ]
      else
        if excess > 0 do
          [
            %{
              kind: "expired",
              credit_lot_id: lot.id,
              expires_on: lot.expires_on,
              amount_cents: excess
            }
          ]
        else
          []
        end
      end

    absorbed_event =
      if absorbed > 0 do
        [
          %{
            kind: "absorbed",
            credit_lot_id: lot.id,
            expires_on: lot.expires_on,
            amount_cents: absorbed
          }
        ]
      else
        []
      end

    absorbed_event ++ restored
  end

  defp revoke_credit_entitlements(payment_operation_id, occurred_on) do
    Repo.all(
      from(e in CreditEntitlement,
        where: e.payment_operation_id == ^payment_operation_id and e.revoked == false,
        order_by: e.id
      )
    )
    |> Enum.flat_map(fn entitlement ->
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      recovered = min(lot.remaining_cents, entitlement.credit_cents)
      unrecovered = entitlement.credit_cents - recovered

      Repo.update_all(from(l in CreditLot, where: l.id == ^lot.id),
        set: [
          remaining_cents: lot.remaining_cents - recovered,
          unrecovered_clawback_cents: lot.unrecovered_clawback_cents + unrecovered
        ]
      )

      Repo.update_all(from(e in CreditEntitlement, where: e.id == ^entitlement.id),
        set: [revoked: true]
      )

      if recovered > 0 do
        kind =
          if Date.compare(lot.expires_on, occurred_on) == :lt,
            do: "available_removed",
            else: "revoked"

        [
          %{
            kind: kind,
            credit_lot_id: lot.id,
            expires_on: lot.expires_on,
            amount_cents: recovered
          }
        ]
      else
        []
      end
    end)
  end

  defp payment_dispositions(payment_id) do
    Repo.all(
      from(d in CashPaymentDisposition,
        where: d.cash_payment_id == ^payment_id,
        order_by: d.id
      )
    )
  end

  defp disposition_group_adjustments(dispositions) do
    Enum.reduce(dispositions, %{}, fn disposition, by_group ->
      field = disposition_group_field(disposition.kind)

      Map.update(
        by_group,
        disposition.group_id,
        %{field => -disposition.amount_cents},
        fn fields ->
          Map.update(fields, field, -disposition.amount_cents, &(&1 - disposition.amount_cents))
        end
      )
    end)
  end

  defp disposition_group_field("refunded"), do: :refunded_cents
  defp disposition_group_field("retained"), do: :retained_cents
  defp disposition_group_field("converted"), do: :cash_converted_to_credit_cents

  defp cash_events_by_group(amounts_by_group, kind) do
    Enum.map(amounts_by_group, fn {group_id, amount} ->
      group = Repo.get!(Group, group_id)
      %{kind: kind, property_id: group.property_id, amount_cents: amount}
    end)
  end

  defp chargeback_disposition_events(dispositions) do
    Enum.flat_map(dispositions, fn disposition ->
      group = Repo.get!(Group, disposition.group_id)

      kind =
        case disposition.kind do
          "refunded" -> "refunded"
          "retained" -> "retained"
          "converted" -> "converted_to_credit"
        end

      [
        %{
          kind: kind,
          property_id: group.property_id,
          amount_cents: -disposition.amount_cents
        },
        %{
          kind: "charged_back",
          property_id: group.property_id,
          amount_cents: disposition.amount_cents
        }
      ]
    end)
  end

  defp remove_cash_allocations(_operation_id, 0), do: %{}

  defp remove_cash_allocations(operation_id, amount) do
    allocations =
      Repo.all(
        from(a in RoomFundingAllocation,
          where: a.kind == "cash" and a.operation_id == ^operation_id,
          order_by: [desc: a.id]
        )
      )

    {left, amounts_by_group} =
      Enum.reduce_while(allocations, {amount, %{}}, fn allocation, {left, amounts_by_group} ->
        removed = min(allocation.amount_cents, left)

        if removed == allocation.amount_cents do
          Repo.delete!(allocation)
        else
          Repo.update_all(from(a in RoomFundingAllocation, where: a.id == ^allocation.id),
            set: [amount_cents: allocation.amount_cents - removed]
          )
        end

        amounts_by_group =
          Map.update(amounts_by_group, allocation.group_id, removed, &(&1 + removed))

        if removed == left,
          do: {:halt, {0, amounts_by_group}},
          else: {:cont, {left - removed, amounts_by_group}}
      end)

    if left != 0, do: raise("cash allocation underflow")
    amounts_by_group
  end

  defp refresh_group_funding(group_ids, adjustments \\ %{}) do
    group_ids
    |> Enum.uniq()
    |> Map.new(fn group_id ->
      group = Repo.get!(Group, group_id)
      totals = active_totals(group_id)

      counter_updates =
        adjustments
        |> Map.get(group_id, %{})
        |> Map.new(fn {field, change} -> {field, Map.fetch!(group, field) + change} end)

      updates =
        Map.merge(
          %{
            deposit_paid_cents: totals.paid,
            credit_paid_cents: totals.credit,
            revision: group.revision + 1
          },
          counter_updates
        )

      {1, _} =
        Repo.update_all(from(g in Group, where: g.id == ^group_id), set: Map.to_list(updates))

      {group_id, %{revision: group.revision + 1, totals: totals}}
    end)
  end

  defp active_totals(group_id) do
    rooms = Repo.all(from(r in Room, where: r.group_id == ^group_id and r.status == "active"))
    room_ids = Enum.map(rooms, & &1.id)

    {cash, credit} =
      if room_ids == [] do
        {0, 0}
      else
        Repo.all(
          from(a in RoomFundingAllocation,
            where: a.room_id in ^room_ids,
            select: {a.kind, a.amount_cents}
          )
        )
        |> Enum.reduce({0, 0}, fn
          {"cash", amount}, {cash, credit} -> {cash + amount, credit}
          {"credit", amount}, {cash, credit} -> {cash, credit + amount}
        end)
      end

    %{
      active_room_count: length(rooms),
      lodging: Enum.reduce(rooms, 0, &(&1.lodging_total_cents + &2)),
      due: Enum.reduce(rooms, 0, &(&1.deposit_due_cents + &2)),
      paid: cash + credit,
      credit: credit
    }
  end

  defp allocation_sum(kind) do
    Repo.all(from(a in RoomFundingAllocation, where: a.kind == ^kind, select: a.amount_cents))
    |> Enum.sum()
  end

  defp held_cash(operation_id) do
    Repo.all(
      from(a in RoomFundingAllocation,
        where: a.kind == "cash" and a.operation_id == ^operation_id,
        select: a.amount_cents
      )
    )
    |> Enum.sum()
  end

  defp held_cash_by_group(operation_id) do
    Repo.all(
      from(a in RoomFundingAllocation,
        join: g in Group,
        on: g.id == a.group_id,
        where: a.kind == "cash" and a.operation_id == ^operation_id,
        group_by: g.group_id,
        order_by: g.group_id,
        select: %{group_id: g.group_id, amount_cents: sum(a.amount_cents)}
      )
    )
  end

  defp prepare_reschedule(group, operation, occurred_on) do
    case parse_date(operation["new_arrival_on"]) do
      {:ok, new_arrival} ->
        if Date.compare(new_arrival, occurred_on) == :gt do
          stay_length = Date.diff(group.departure_on, group.arrival_on)
          new_departure = Date.add(new_arrival, stay_length)

          if new_departure.year <= 9999 do
            moved_group = %{group | arrival_on: new_arrival, departure_on: new_departure}

            {:ok, [arrival_on: new_arrival, departure_on: new_departure],
             [
               group_id: group.group_id,
               new_arrival_on: new_arrival,
               new_departure_on: new_departure,
               policy_version: policy_version(group),
               refundable_until: refundable_until(moved_group)
             ]}
          else
            {:error, "invalid_stay"}
          end
        else
          {:error, "invalid_stay"}
        end

      _ ->
        {:error, "invalid_stay"}
    end
  end

  defp available_lots(guest_id, on) do
    Repo.all(
      from(l in CreditLot,
        where: l.guest_id == ^guest_id and l.expires_on >= ^on and l.remaining_cents > 0,
        order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
      )
    )
  end

  defp apply_update(group, updates, operation_id, fields, operation) do
    case persist_group_update(group, updates, operation_id, operation) do
      {:ok, revision} -> applied(operation_id, Keyword.put(fields, :revision, revision))
      {:error, result} -> result
    end
  end

  defp persist_group_update(group, updates, operation_id, operation) do
    next_revision = group.revision + 1

    {count, _} =
      Repo.update_all(
        from(g in Group, where: g.id == ^group.id and g.revision == ^group.revision),
        set: Keyword.put(updates, :revision, next_revision)
      )

    if count == 1 do
      {:ok, next_revision}
    else
      actual_revision = Repo.get!(Group, group.id).revision

      result =
        if Map.has_key?(operation, "expected_revision") do
          stale(operation_id, group.group_id, operation["expected_revision"], actual_revision)
        else
          rejected(operation_id, "invalid_operation")
        end

      {:error, result}
    end
  end

  defp validate_revision(group, operation, operation_id) do
    validate_revision(group, operation, operation_id, "expected_revision")
  end

  defp validate_revision(group, operation, operation_id, key) do
    case Map.fetch(operation, key) do
      :error ->
        :ok

      {:ok, expected} when expected == group.revision ->
        :ok

      {:ok, expected} ->
        {:rejected, stale(operation_id, group.group_id, expected, group.revision)}
    end
  end

  defp validate_active(%Group{status: "active"}, _operation_id), do: :ok

  defp validate_active(group, operation_id) do
    {:rejected, rejected(operation_id, "group_not_active", group_id: group.group_id)}
  end

  defp validate_stay(operation) do
    with {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         nights when nights > 0 <- Date.diff(departure_on, arrival_on) do
      {:ok, arrival_on, departure_on, nights}
    else
      _ -> {:error, "invalid_stay"}
    end
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn room ->
        is_map(room) and valid_identifier?(room["room_id"]) and
          is_integer(room["nightly_rate_cents"]) and room["nightly_rate_cents"] > 0 and
          room["nightly_rate_cents"] <= @max_sqlite_integer
      end)

    room_ids = Enum.map(rooms, &Map.get(&1, "room_id"))

    if valid and Enum.uniq(room_ids) == room_ids do
      {:ok,
       rooms
       |> Enum.with_index()
       |> Enum.map(fn {room, position} ->
         %{
           room_id: room["room_id"],
           nightly_rate_cents: room["nightly_rate_cents"],
           position: position,
           status: "active"
         }
       end)}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}
  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: {:ok, rate_plan}
  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp calculate_totals(rooms, nights, rate_plan) do
    rooms =
      Enum.map(rooms, fn room ->
        lodging = room.nightly_rate_cents * nights
        due = if rate_plan == "flexible", do: round_percentage(lodging, 20), else: lodging
        Map.merge(room, %{lodging_total_cents: lodging, deposit_due_cents: due})
      end)

    lodging_total = Enum.reduce(rooms, 0, &(&1.lodging_total_cents + &2))
    deposit_due = Enum.reduce(rooms, 0, &(&1.deposit_due_cents + &2))

    if lodging_total <= @max_sqlite_integer and deposit_due <= @max_sqlite_integer do
      {:ok, rooms, lodging_total, deposit_due}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp policy_version(%Group{policy_version: nil} = group),
    do: policy_version(group.rate_plan, group.booked_on)

  defp policy_version(%Group{policy_version: version}), do: version
  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, @policy_cutoff) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until(group) do
    case policy_version(group) do
      "flex-14" -> Date.add(group.arrival_on, -14)
      "flex-30" -> Date.add(group.arrival_on, -30)
      "advance-nonrefundable" -> nil
    end
  end

  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      date -> Date.compare(occurred_on, date) in [:lt, :eq]
    end
  end

  defp parse_common_date(operation) do
    if Map.has_key?(operation, "occurred_on"),
      do: parse_date(operation["occurred_on"]),
      else: :error
  end

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_value), do: :error

  defp parse_read_date(value) when is_binary(value) do
    case Regex.run(~r/^(\d{4,5})-(\d{2})-(\d{2})$/, value) do
      [_, year, month, day] ->
        Date.new(String.to_integer(year), String.to_integer(month), String.to_integer(day))

      _ ->
        :error
    end
  end

  defp parse_read_date(_value), do: :error
  defp valid_identifier?(value), do: is_binary(value) and value != ""
  defp submitted_type(%{"type" => type}) when is_binary(type), do: type
  defp submitted_type(_operation), do: nil
  defp valid_amount?(amount), do: is_integer(amount) and amount > 0
  defp round_percentage(value, percentage), do: div(value * percentage + 50, 100)

  defp outstanding(%Group{status: "active"} = group) do
    group.deposit_due_cents - group.deposit_paid_cents
  end

  defp outstanding(%Group{}), do: 0

  defp applied_cash_operation?(operation) do
    operation.type == "record_cash_payment" and operation.result["status"] == "applied"
  end

  defp applied(operation_id, fields) do
    fields |> Map.new() |> Map.merge(%{operation_id: operation_id, status: "applied"})
  end

  defp rejected(operation_id, code, fields \\ []) do
    fields
    |> Map.new()
    |> Map.merge(%{operation_id: operation_id, status: "rejected", code: code})
  end

  defp stale(operation_id, group_id, expected, actual) do
    rejected(operation_id, "stale_revision",
      group_id: group_id,
      expected_revision: expected,
      actual_revision: actual
    )
  end

  defp transaction_result({:ok, result}), do: result
end
