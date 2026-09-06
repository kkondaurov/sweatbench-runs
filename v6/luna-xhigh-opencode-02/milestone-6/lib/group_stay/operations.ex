defmodule GroupStay.Operations do
  import Ecto.Query

  alias GroupStay.Groups

  alias GroupStay.Groups.{
    CashAllocation,
    CreditAllocation,
    CreditLot,
    CreditLotContribution,
    Group,
    Room,
    AllocationSequence
  }

  alias GroupStay.Finance
  alias GroupStay.Operations.Operation
  alias GroupStay.Repo

  @valid_rate_plans ["flexible", "advance_purchase"]
  @valid_refund_methods ["cash", "hotel_credit"]

  @doc "Processes partner operations independently and in the order supplied."
  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  defp process_operation(operation) when not is_map(operation),
    do: rejected(nil, "invalid_operation")

  defp process_operation(operation) do
    if valid_identifier?(operation_id(operation)) do
      process_durable_operation(operation)
    else
      process_operation_body(operation)
    end
  end

  def result_for(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil -> nil
      operation -> operation.result
    end
  end

  def payment_reconciliation(operation_id) do
    Repo.transaction(fn -> payment_reconciliation_in_transaction(operation_id) end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp payment_reconciliation_in_transaction(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil ->
        {:error, :operation_not_found}

      %Operation{type: "record_cash_payment", result: result} = operation when is_map(result) ->
        if result["status"] == "applied" do
          dispositions = Groups.payment_dispositions(operation.operation_id)

          payment =
            %{
              payment_operation_id: operation.operation_id,
              original_group_id: result["group_id"],
              recorded_cents: result["amount_cents"],
              held_cents: dispositions.held_cents,
              refunded_cents: dispositions.refunded_cents,
              retained_cents: dispositions.retained_cents,
              converted_to_credit_cents: dispositions.converted_to_credit_cents,
              reduced_cents: dispositions.reduced_cents,
              charged_back_cents: dispositions.charged_back_cents
            }
            |> maybe_add_held_by_group(operation.operation_id)

          {:ok, payment}
        else
          {:error, :payment_not_reconcilable}
        end

      _operation ->
        {:error, :payment_not_reconcilable}
    end
  end

  defp maybe_add_held_by_group(payment, operation_id) do
    if Groups.payment_transferred?(operation_id) do
      Map.put(payment, :held_by_group, Groups.held_cash_by_group(operation_id))
    else
      payment
    end
  end

  defp process_durable_operation(operation) do
    with_write_lock(fn ->
      Repo.transaction(fn ->
        case claim_operation(operation) do
          {:new, record} ->
            reporting_snapshot = if Finance.reporting(), do: Finance.snapshot()
            result = process_operation_body(operation)

            if applied_result?(result) and reporting_snapshot do
              Finance.record_operation(operation, reporting_snapshot, Finance.snapshot())
            end

            remember_operation!(record, result)

          {:existing, record} ->
            if record.payload == operation do
              record.result
            else
              rejected(operation, "operation_id_conflict")
            end
        end
      end)
    end)
    |> transaction_result()
  end

  defp process_operation_body(operation) do
    case operation["type"] do
      "open_group" -> open_group(operation)
      "record_cash_payment" -> update_group(operation, :payment)
      "apply_hotel_credit" -> update_group(operation, :credit)
      "reschedule_group" -> update_group(operation, :reschedule)
      "cancel_group" -> update_group(operation, :cancel)
      "cancel_rooms" -> update_group(operation, :cancel_rooms)
      "transfer_deposit" -> transfer_deposit(operation)
      "reduce_cash_payment" -> reduce_cash_payment(operation)
      "charge_back_payment" -> charge_back_payment(operation)
      "start_finance_reporting" -> start_finance_reporting(operation)
      _ -> rejected(operation, "invalid_operation")
    end
  end

  defp open_group(operation) do
    with :ok <- validate_common(operation),
         :ok <- validate_identifiers(operation, ["group_id", "guest_id", "property_id"]) do
      group_id = operation["group_id"]

      if Repo.get(Group, group_id) do
        rejected(operation, "group_already_exists")
      else
        case open_details(operation) do
          {:ok, details} ->
            attrs = %{
              group_id: group_id,
              guest_id: operation["guest_id"],
              property_id: operation["property_id"],
              booked_on: details.booked_on,
              arrival_on: details.arrival_on,
              departure_on: details.departure_on,
              rate_plan: operation["rate_plan"],
              policy_version: details.policy_version,
              status: "active",
              lodging_total_cents: details.lodging_total_cents,
              deposit_due_cents: details.deposit_due_cents,
              deposit_paid_cents: 0,
              cash_paid_cents: 0,
              credit_paid_cents: 0,
              cash_refunded_cents: 0,
              cash_retained_cents: 0,
              cash_converted_to_credit_cents: 0,
              revision: 1
            }

            case Groups.insert_group(attrs, details.rooms) do
              {:ok, _group} ->
                applied(operation, %{
                  group_id: group_id,
                  deposit_due_cents: details.deposit_due_cents,
                  revision: 1
                })

              {:error, _reason} ->
                Repo.rollback(:group_insert_failed)
            end

          {:error, code} ->
            rejected(operation, code)
        end
      end
    else
      {:error, code} -> rejected(operation, code)
    end
  end

  defp start_finance_reporting(operation) do
    case validate_operation_id(operation) do
      :ok ->
        case parse_date(operation["starts_on"]) do
          {:ok, starts_on} ->
            case Finance.reporting() do
              nil ->
                Finance.start_reporting!(starts_on, Finance.snapshot())
                applied(operation, %{starts_on: Date.to_iso8601(starts_on)})

              _reporting ->
                rejected(operation, "reporting_already_started")
            end

          {:error, _reason} ->
            rejected(operation, "invalid_reporting_date")
        end

      {:error, _reason} ->
        rejected(operation, "invalid_operation")
    end
  end

  defp update_group(operation, kind) do
    with :ok <- validate_operation_id(operation),
         :ok <- validate_identifiers(operation, ["group_id"]) do
      group_id = operation["group_id"]

      case Repo.get(Group, group_id) do
        nil ->
          rejected(operation, "group_not_found")

        group ->
          case check_expected_revision(operation, group) do
            :ok -> apply_group_operation(operation, kind, group)
            {:error, stale} -> stale
          end
      end
    else
      {:error, code} -> rejected(operation, code)
    end
  end

  defp apply_group_operation(operation, :payment, %Group{status: status} = group) do
    if status != "active" do
      rejected(operation, "group_not_active")
    else
      amount = operation["amount_cents"]
      totals = Groups.totals(group.group_id)

      cond do
        not usable_amount?(amount) ->
          rejected(operation, "invalid_amount")

        amount > outstanding(totals) ->
          rejected(operation, "payment_exceeds_outstanding")

        not valid_date?(operation["occurred_on"]) ->
          rejected(operation, "invalid_operation")

        true ->
          allocate_cash!(group.group_id, amount, operation_id(operation))
          updated = update_group_with_totals!(group, %{})

          applied(operation, %{
            group_id: group.group_id,
            amount_cents: amount,
            outstanding_deposit_cents: outstanding(Groups.totals(group.group_id)),
            revision: updated.revision
          })
      end
    end
  end

  defp apply_group_operation(operation, :credit, %Group{status: status} = group) do
    if status != "active" do
      rejected(operation, "group_not_active")
    else
      amount = operation["amount_cents"]
      totals = Groups.totals(group.group_id)

      cond do
        not usable_amount?(amount) ->
          rejected(operation, "invalid_amount")

        amount > outstanding(totals) ->
          rejected(operation, "payment_exceeds_outstanding")

        true ->
          case parse_date(operation["occurred_on"]) do
            {:ok, occurred_on} ->
              lots = available_credit_lots(group.guest_id, occurred_on)

              if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
                rejected(operation, "insufficient_credit")
              else
                allocate_credit!(group, lots, amount, operation_id(operation))
                updated = update_group_with_totals!(group, %{})

                applied(operation, %{
                  group_id: group.group_id,
                  amount_cents: amount,
                  outstanding_deposit_cents: outstanding(Groups.totals(group.group_id)),
                  revision: updated.revision
                })
              end

            {:error, _reason} ->
              rejected(operation, "invalid_operation")
          end
      end
    end
  end

  defp apply_group_operation(operation, :reschedule, %Group{status: status} = group) do
    if status != "active" do
      rejected(operation, "group_not_active")
    else
      with {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
           {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"]),
           true <- Date.compare(new_arrival_on, occurred_on) == :gt do
        nights = Date.diff(group.departure_on, group.arrival_on)
        new_departure_on = Date.add(new_arrival_on, nights)

        updated =
          update_group!(group, %{
            arrival_on: new_arrival_on,
            departure_on: new_departure_on
          })

        applied(operation, %{
          group_id: group.group_id,
          new_arrival_on: Date.to_iso8601(updated.arrival_on),
          new_departure_on: Date.to_iso8601(updated.departure_on),
          policy_version: Groups.policy_version(updated),
          refundable_until: serialize_date(Groups.refundable_until(updated)),
          revision: updated.revision
        })
      else
        _ -> rejected(operation, "invalid_stay")
      end
    end
  end

  defp apply_group_operation(operation, :cancel, %Group{status: status} = group) do
    if status != "active" do
      rejected(operation, "group_not_active")
    else
      with {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
           {:ok, refund_method} <- cancellation_refund_method(operation) do
        rooms =
          Groups.rooms_with_funding(group.group_id)
          |> Enum.filter(&(&1.status == "active"))

        settle_selected_rooms(operation, group, rooms, occurred_on, refund_method, false)
      else
        {:error, "invalid_operation"} -> rejected(operation, "invalid_operation")
        _ -> rejected(operation, "invalid_stay")
      end
    end
  end

  defp apply_group_operation(operation, :cancel_rooms, %Group{status: status} = group) do
    if status != "active" do
      rejected(operation, "group_not_active")
    else
      with {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
           {:ok, refund_method} <- cancellation_refund_method(operation),
           {:ok, rooms} <- selected_rooms(group.group_id, operation["room_ids"]) do
        settle_selected_rooms(operation, group, rooms, occurred_on, refund_method, true)
      else
        {:error, "invalid_rooms"} -> rejected(operation, "invalid_rooms")
        {:error, "invalid_operation"} -> rejected(operation, "invalid_operation")
        _ -> rejected(operation, "invalid_stay")
      end
    end
  end

  defp transfer_deposit(operation) do
    with :ok <- validate_operation_id(operation),
         :ok <- validate_identifiers(operation, ["source_group_id", "destination_group_id"]) do
      source_group_id = operation["source_group_id"]
      destination_group_id = operation["destination_group_id"]

      case Repo.get(Group, source_group_id) do
        nil ->
          rejected_with_group(operation, "group_not_found", source_group_id)

        source ->
          case Repo.get(Group, destination_group_id) do
            nil ->
              rejected_with_group(operation, "group_not_found", destination_group_id)

            destination ->
              with :ok <- check_expected_revision(operation, source),
                   :ok <-
                     check_expected_revision(
                       operation,
                       "destination_expected_revision",
                       destination
                     ) do
                apply_transfer(operation, source, destination)
              else
                {:error, stale} -> stale
              end
          end
      end
    else
      {:error, code} -> rejected(operation, code)
    end
  end

  defp apply_transfer(operation, source, destination) do
    cond do
      source.group_id == destination.group_id or source.guest_id != destination.guest_id ->
        rejected(operation, "invalid_transfer")

      source.status != "active" ->
        rejected_with_group(operation, "group_not_active", source.group_id)

      destination.status != "active" ->
        rejected_with_group(operation, "group_not_active", destination.group_id)

      not usable_amount?(operation["amount_cents"]) ->
        rejected(operation, "invalid_amount")

      operation["amount_cents"] > held_funding(source.group_id) ->
        rejected(operation, "transfer_exceeds_held_funding")

      operation["amount_cents"] > outstanding(Groups.totals(destination.group_id)) ->
        rejected(operation, "transfer_exceeds_outstanding")

      true ->
        transfer_funding!(
          source.group_id,
          destination.group_id,
          operation["amount_cents"]
        )

        updated_groups =
          update_changed_groups!(
            source.group_id,
            MapSet.new([source.group_id, destination.group_id])
          )

        updated_source = Map.fetch!(updated_groups, source.group_id)
        updated_destination = Map.fetch!(updated_groups, destination.group_id)

        applied(operation, %{
          source_group_id: source.group_id,
          destination_group_id: destination.group_id,
          amount_cents: operation["amount_cents"],
          source_outstanding_deposit_cents: outstanding(Groups.totals(source.group_id)),
          destination_outstanding_deposit_cents: outstanding(Groups.totals(destination.group_id)),
          source_revision: updated_source.revision,
          destination_revision: updated_destination.revision
        })
    end
  end

  defp transfer_funding!(source_group_id, destination_group_id, amount) do
    allocations = held_allocations_for_transfer(source_group_id)
    units = take_transfer_units(allocations, amount)
    destination_rooms = transfer_destination_rooms(destination_group_id)
    {_rooms, chunks} = transfer_destination_chunks(units, destination_rooms)

    source_changes =
      Enum.reduce(units, %{}, fn %{kind: kind, allocation: allocation, amount: amount}, changes ->
        key = {kind, allocation.id}

        Map.update(
          changes,
          key,
          {allocation, amount},
          fn {same_allocation, current_amount} -> {same_allocation, current_amount + amount} end
        )
      end)

    Enum.each(source_changes, fn
      {{:cash, _id}, {allocation, moved}} ->
        allocation
        |> Ecto.Changeset.change(
          held_cents: allocation.held_cents - moved,
          transferred: true
        )
        |> Repo.update!()

      {{:credit, _id}, {allocation, moved}} ->
        allocation
        |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - moved)
        |> Repo.update!()
    end)

    Enum.each(chunks, fn %{kind: kind, allocation: allocation, room_id: room_id, amount: amount} ->
      case kind do
        :cash ->
          Repo.insert!(%CashAllocation{
            group_id: destination_group_id,
            room_id: room_id,
            payment_operation_id: allocation.payment_operation_id,
            original_cents: amount,
            held_cents: amount,
            refunded_cents: 0,
            retained_cents: 0,
            converted_to_credit_cents: 0,
            reduced_cents: 0,
            charged_back_cents: 0,
            transferred: true,
            allocation_order: next_allocation_order!()
          })

        :credit ->
          Repo.insert!(%CreditAllocation{
            group_id: destination_group_id,
            room_id: room_id,
            credit_lot_id: allocation.credit_lot_id,
            amount_cents: amount,
            operation_id: allocation.operation_id,
            allocation_order: next_allocation_order!()
          })
      end
    end)
  end

  defp held_allocations_for_transfer(group_id) do
    cash =
      from(a in CashAllocation,
        join: r in Room,
        on: r.id == a.room_id,
        where: a.group_id == ^group_id and a.held_cents > 0 and r.status == "active",
        select: a
      )
      |> Repo.all()
      |> Enum.map(&%{kind: :cash, allocation: &1, amount: &1.held_cents})

    credit =
      from(a in CreditAllocation,
        join: r in Room,
        on: r.id == a.room_id,
        where: a.group_id == ^group_id and a.amount_cents > 0 and r.status == "active",
        select: a
      )
      |> Repo.all()
      |> Enum.map(&%{kind: :credit, allocation: &1, amount: &1.amount_cents})

    Enum.sort_by(cash ++ credit, fn %{allocation: allocation} ->
      {allocation.allocation_order, allocation.id}
    end)
  end

  defp held_funding(group_id) do
    held_allocations_for_transfer(group_id)
    |> Enum.map(& &1.amount)
    |> Enum.sum()
  end

  defp take_transfer_units(allocations, amount) do
    {remaining, units} =
      allocations
      |> Enum.reverse()
      |> Enum.reduce_while({amount, []}, fn allocation, {remaining, units} ->
        take = min(remaining, allocation.amount)
        next_remaining = remaining - take
        units = if take > 0, do: units ++ [%{allocation | amount: take}], else: units

        if next_remaining == 0,
          do: {:halt, {0, units}},
          else: {:cont, {next_remaining, units}}
      end)

    if remaining == 0, do: units, else: raise("transfer allocation underflow")
  end

  defp transfer_destination_rooms(group_id) do
    Groups.rooms_with_funding(group_id)
    |> Enum.filter(&(&1.status == "active"))
    |> Enum.map(fn room ->
      {room.id, max(room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents, 0)}
    end)
  end

  defp transfer_destination_chunks(units, rooms) do
    Enum.reduce(units, {rooms, []}, fn unit, {rooms, chunks} ->
      {rooms, unit_chunks} = fill_transfer_rooms(rooms, unit, unit.amount, [])
      {rooms, chunks ++ unit_chunks}
    end)
  end

  defp fill_transfer_rooms([{room_id, capacity} | rest], unit, amount, chunks) do
    take = min(amount, capacity)
    chunk = unit |> Map.put(:room_id, room_id) |> Map.put(:amount, take)
    chunks = if take > 0, do: chunks ++ [chunk], else: chunks
    remaining = amount - take

    if remaining == 0 do
      {[{room_id, capacity - take} | rest], chunks}
    else
      {rest, chunks} = fill_transfer_rooms(rest, unit, remaining, chunks)
      {[{room_id, 0} | rest], chunks}
    end
  end

  defp fill_transfer_rooms([], _unit, amount, _chunks) when amount > 0,
    do: raise("transfer destination underflow")

  defp settle_selected_rooms(operation, group, rooms, occurred_on, refund_method, include_rooms) do
    refundable = Groups.refundable?(group, occurred_on)
    room_ids = Enum.map(rooms, & &1.id)

    cond do
      refund_method == "hotel_credit" and not refundable ->
        rejected(operation, "refund_method_not_available")

      refundable ->
        restore_credit_allocations(room_ids, occurred_on)
        cash_allocations = held_cash_allocations(room_ids)
        cash_paid = Enum.sum(Enum.map(cash_allocations, & &1.held_cents))

        {refunded, retained, converted, credit_issued} =
          settle_refundable_cash(
            operation,
            group,
            cash_allocations,
            cash_paid,
            refund_method,
            occurred_on
          )

        finish_room_cancellation(
          operation,
          group,
          rooms,
          refunded,
          retained,
          converted,
          credit_issued,
          include_rooms
        )

      true ->
        consume_credit_allocations(room_ids)
        cash_allocations = held_cash_allocations(room_ids)
        cash_paid = Enum.sum(Enum.map(cash_allocations, & &1.held_cents))
        settle_cash_allocations(cash_allocations, :retained)

        finish_room_cancellation(
          operation,
          group,
          rooms,
          0,
          cash_paid,
          0,
          0,
          include_rooms
        )
    end
  end

  defp settle_refundable_cash(
         operation,
         group,
         cash_allocations,
         cash_paid,
         refund_method,
         occurred_on
       ) do
    case refund_method do
      "cash" ->
        settle_cash_allocations(cash_allocations, :refunded)
        {cash_paid, 0, 0, 0}

      "hotel_credit" ->
        settle_cash_allocations(cash_allocations, :converted)
        credit_issued = cash_paid + round_percentage(cash_paid, 10, 100)

        if credit_issued > 0 do
          lot =
            Repo.insert!(%CreditLot{
              guest_id: group.guest_id,
              source_operation_id: operation_id(operation),
              remaining_cents: credit_issued,
              expires_on: Date.add(occurred_on, 365),
              unrecovered_clawback_cents: 0
            })

          add_credit_contributions(lot, cash_allocations)
        end

        {0, 0, cash_paid, credit_issued}
    end
  end

  defp finish_room_cancellation(
         operation,
         group,
         rooms,
         refunded,
         retained,
         converted,
         credit_issued,
         include_rooms
       ) do
    Enum.each(rooms, fn room ->
      room
      |> Ecto.Changeset.change(status: "cancelled")
      |> Repo.update!()
    end)

    active_remaining? =
      from(r in Room,
        where: r.group_id == ^group.group_id and r.status == "active",
        select: count(r.id)
      )
      |> Repo.one() > 0

    cancellation_attrs = %{
      status: if(active_remaining?, do: "active", else: "cancelled"),
      cash_refunded_cents: group.cash_refunded_cents + refunded,
      cash_retained_cents: group.cash_retained_cents + retained,
      cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted
    }

    updated =
      if active_remaining? do
        update_group_with_totals!(group, cancellation_attrs)
      else
        # Keep the original aggregate paid fields for the established full-
        # cancellation response; room rows and active-group totals are zero.
        update_group!(group, cancellation_attrs)
      end

    result = %{
      group_id: group.group_id,
      refunded_cents: refunded,
      retained_cents: retained,
      credit_issued_cents: credit_issued,
      revision: updated.revision
    }

    if include_rooms do
      Map.put(result, :cancelled_room_ids, Enum.map(rooms, & &1.room_id))
    else
      result
    end
    |> then(&applied(operation, &1))
  end

  defp reduce_cash_payment(operation) do
    with :ok <- validate_operation_id(operation),
         :ok <- validate_payment_identifier(operation["payment_operation_id"]) do
      case durable_payment_target(operation["payment_operation_id"], "payment_not_reducible") do
        {:error, code} ->
          rejected(operation, code)

        {:ok, target, group} ->
          case check_expected_revision(operation, group) do
            {:error, stale} ->
              stale

            :ok ->
              amount = operation["amount_cents"]
              held = held_for_payment(target.operation_id)

              cond do
                not usable_amount?(amount) ->
                  rejected(operation, "invalid_amount")

                held == 0 ->
                  rejected(operation, "payment_not_reducible")

                amount > held ->
                  rejected(operation, "reduction_exceeds_held_cash")

                true ->
                  changed_group_ids = reduce_allocations(target.operation_id, amount)
                  updated_groups = update_changed_groups!(group.group_id, changed_group_ids)
                  updated = Map.fetch!(updated_groups, group.group_id)

                  applied(operation, %{
                    payment_operation_id: target.operation_id,
                    group_id: group.group_id,
                    amount_cents: amount,
                    outstanding_deposit_cents: outstanding(Groups.totals(group.group_id)),
                    revision: updated.revision
                  })
              end
          end
      end
    else
      {:error, code} -> rejected(operation, code)
    end
  end

  defp charge_back_payment(operation) do
    with :ok <- validate_operation_id(operation),
         :ok <- validate_payment_identifier(operation["payment_operation_id"]) do
      case durable_payment_target(operation["payment_operation_id"], "payment_not_chargeable") do
        {:error, code} ->
          rejected(operation, code)

        {:ok, target, group} ->
          case check_expected_revision(operation, group) do
            {:error, stale} ->
              stale

            :ok ->
              allocations = cash_allocations_for_payment(target.operation_id)
              chargeable = Enum.sum(Enum.map(allocations, &chargeable_amount/1))

              if chargeable == 0 do
                rejected(operation, "payment_not_chargeable")
              else
                changed_group_ids =
                  allocations
                  |> Enum.filter(&(chargeable_amount(&1) > 0))
                  |> Enum.map(& &1.group_id)
                  |> MapSet.new()

                Enum.each(allocations, &charge_back_allocation/1)
                revoke_credit_entitlements(target.operation_id)
                updated_groups = update_changed_groups!(group.group_id, changed_group_ids)
                updated = Map.fetch!(updated_groups, group.group_id)

                applied(operation, %{
                  payment_operation_id: target.operation_id,
                  group_id: group.group_id,
                  charged_back_cents: chargeable,
                  outstanding_deposit_cents: outstanding(Groups.totals(group.group_id)),
                  revision: updated.revision
                })
              end
          end
      end
    else
      {:error, code} -> rejected(operation, code)
    end
  end

  defp durable_payment_target(payment_operation_id, invalid_code) do
    case Repo.get_by(Operation, operation_id: payment_operation_id) do
      nil ->
        {:error, "operation_not_found"}

      %Operation{type: "record_cash_payment", result: result} = target when is_map(result) ->
        if result["status"] == "applied" and valid_identifier?(result["group_id"]) do
          case Repo.get(Group, result["group_id"]) do
            nil -> {:error, invalid_code}
            group -> {:ok, target, group}
          end
        else
          {:error, invalid_code}
        end

      _target ->
        {:error, invalid_code}
    end
  end

  defp held_for_payment(operation_id) do
    Repo.one(
      from a in CashAllocation,
        where: a.payment_operation_id == ^operation_id,
        select: coalesce(sum(a.held_cents), 0)
    )
  end

  defp reduce_allocations(operation_id, amount) do
    allocations = cash_allocations_for_payment(operation_id)

    {_remaining, group_ids} =
      Enum.reduce_while(allocations, {amount, MapSet.new()}, fn allocation,
                                                                {remaining, group_ids} ->
        reduction = min(remaining, allocation.held_cents)

        if reduction > 0 do
          allocation
          |> Ecto.Changeset.change(
            held_cents: allocation.held_cents - reduction,
            reduced_cents: allocation.reduced_cents + reduction
          )
          |> Repo.update!()
        end

        next = remaining - reduction

        group_ids =
          if reduction > 0, do: MapSet.put(group_ids, allocation.group_id), else: group_ids

        if next == 0, do: {:halt, {0, group_ids}}, else: {:cont, {next, group_ids}}
      end)

    group_ids
  end

  defp charge_back_allocation(allocation) do
    amount = chargeable_amount(allocation)

    if amount > 0 do
      allocation
      |> Ecto.Changeset.change(
        held_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0,
        charged_back_cents: allocation.charged_back_cents + amount
      )
      |> Repo.update!()
    end
  end

  defp revoke_credit_entitlements(operation_id) do
    from(c in CreditLotContribution,
      where: c.payment_operation_id == ^operation_id,
      order_by: [asc: c.id]
    )
    |> Repo.all()
    |> Enum.each(fn contribution ->
      lot = Repo.get!(CreditLot, contribution.credit_lot_id)
      removed = min(lot.remaining_cents, contribution.entitlement_cents)

      lot
      |> Ecto.Changeset.change(
        remaining_cents: lot.remaining_cents - removed,
        unrecovered_clawback_cents:
          (lot.unrecovered_clawback_cents || 0) + contribution.entitlement_cents - removed
      )
      |> Repo.update!()
    end)
  end

  defp open_details(operation) do
    with {:ok, booked_on} <- parse_date(operation["occurred_on"]),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         true <- Date.compare(departure_on, arrival_on) == :gt,
         {:ok, rooms} <- validate_rooms(operation["rooms"]),
         :ok <- validate_rate_plan(operation["rate_plan"]) do
      nights = Date.diff(departure_on, arrival_on)

      room_totals =
        Enum.map(rooms, fn room ->
          lodging = nights * room.nightly_rate_cents
          deposit = deposit_for(operation["rate_plan"], lodging)
          Map.merge(room, %{lodging_cents: lodging, deposit_due_cents: deposit, status: "active"})
        end)

      {:ok,
       %{
         booked_on: booked_on,
         arrival_on: arrival_on,
         departure_on: departure_on,
         policy_version: Groups.policy_version_for(operation["rate_plan"], booked_on),
         rooms:
           Enum.with_index(room_totals)
           |> Enum.map(fn {room, position} -> Map.put(room, :position, position) end),
         lodging_total_cents: Enum.sum(Enum.map(room_totals, & &1.lodging_cents)),
         deposit_due_cents: Enum.sum(Enum.map(room_totals, & &1.deposit_due_cents))
       }}
    else
      false -> {:error, "invalid_stay"}
      {:error, "invalid_rooms"} -> {:error, "invalid_rooms"}
      {:error, "invalid_rate_plan"} -> {:error, "invalid_rate_plan"}
      {:error, _reason} -> {:error, "invalid_stay"}
    end
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    rooms
    |> Enum.reduce_while({:ok, MapSet.new(), []}, fn room, {:ok, ids, valid_rooms} ->
      if is_map(room) and valid_identifier?(room["room_id"]) and
           usable_rate?(room["nightly_rate_cents"]) and
           not MapSet.member?(ids, room["room_id"]) do
        {:cont,
         {:ok, MapSet.put(ids, room["room_id"]),
          [
            %{room_id: room["room_id"], nightly_rate_cents: room["nightly_rate_cents"]}
            | valid_rooms
          ]}}
      else
        {:halt, {:error, "invalid_rooms"}}
      end
    end)
    |> case do
      {:ok, _ids, valid_rooms} -> {:ok, Enum.reverse(valid_rooms)}
      error -> error
    end
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp validate_rate_plan(rate_plan) when rate_plan in @valid_rate_plans, do: :ok
  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp deposit_for("advance_purchase", lodging), do: lodging
  defp deposit_for("flexible", lodging), do: round_percentage(lodging, 20, 100)

  defp available_credit_lots(guest_id, occurred_on) do
    from(l in CreditLot,
      where:
        l.guest_id == ^guest_id and l.remaining_cents > 0 and
          l.expires_on >= ^occurred_on,
      order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
    )
    |> Repo.all()
  end

  defp allocate_cash!(group_id, amount, payment_operation_id) do
    Groups.rooms_with_funding(group_id)
    |> Enum.filter(&(&1.status == "active"))
    |> Enum.reduce_while(amount, fn room, remaining ->
      capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
      allocated = min(remaining, max(capacity, 0))

      if allocated > 0 do
        Repo.insert!(%CashAllocation{
          group_id: group_id,
          room_id: room.id,
          payment_operation_id: payment_operation_id,
          original_cents: allocated,
          held_cents: allocated,
          refunded_cents: 0,
          retained_cents: 0,
          converted_to_credit_cents: 0,
          reduced_cents: 0,
          charged_back_cents: 0,
          transferred: false,
          allocation_order: next_allocation_order!()
        })
      end

      next = remaining - allocated
      if next == 0, do: {:halt, 0}, else: {:cont, next}
    end)
  end

  defp allocate_credit!(group, lots, amount, operation_id) do
    room_caps =
      Groups.rooms_with_funding(group.group_id)
      |> Enum.filter(&(&1.status == "active"))
      |> Enum.map(fn room ->
        {room.id, room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents}
      end)

    {remaining, _room_caps} =
      Enum.reduce_while(lots, {amount, room_caps}, fn lot, {remaining, caps} ->
        lot_amount = min(remaining, lot.remaining_cents)

        {used, next_caps} =
          allocate_credit_lot!(group.group_id, lot, caps, lot_amount, operation_id)

        lot
        |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - used)
        |> Repo.update!()

        next_remaining = remaining - used

        if next_remaining == 0,
          do: {:halt, {0, next_caps}},
          else: {:cont, {next_remaining, next_caps}}
      end)

    remaining
  end

  defp allocate_credit_lot!(group_id, lot, caps, amount, operation_id) do
    Enum.reduce(caps, {0, []}, fn {room_id, capacity}, {used, next_caps} ->
      remaining = amount - used
      take = min(remaining, max(capacity, 0))

      if take > 0 do
        Repo.insert!(%CreditAllocation{
          group_id: group_id,
          room_id: room_id,
          credit_lot_id: lot.id,
          amount_cents: take,
          operation_id: operation_id,
          allocation_order: next_allocation_order!()
        })
      end

      {used + take, next_caps ++ [{room_id, capacity - take}]}
    end)
  end

  defp selected_rooms(group_id, room_ids) when is_list(room_ids) do
    valid_ids = Enum.all?(room_ids, &valid_identifier?/1)

    if valid_ids and room_ids != [] and length(Enum.uniq(room_ids)) == length(room_ids) do
      rooms = Groups.rooms_with_funding(group_id)
      selected = Enum.filter(rooms, &(&1.room_id in room_ids and &1.status == "active"))

      if length(selected) == length(room_ids),
        do: {:ok, selected},
        else: {:error, "invalid_rooms"}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp selected_rooms(_group_id, _room_ids), do: {:error, "invalid_rooms"}

  defp held_cash_allocations(room_ids) do
    from(a in CashAllocation,
      where: a.room_id in ^room_ids and a.held_cents > 0,
      order_by: [asc: a.allocation_order, asc: a.id]
    )
    |> Repo.all()
  end

  defp cash_allocations_for_payment(operation_id) do
    from(a in CashAllocation,
      where: a.payment_operation_id == ^operation_id,
      order_by: [desc: a.allocation_order, desc: a.id]
    )
    |> Repo.all()
  end

  defp settle_cash_allocations(allocations, disposition) do
    Enum.each(allocations, fn allocation ->
      amount = allocation.held_cents

      if amount > 0 do
        attrs =
          case disposition do
            :refunded ->
              [held_cents: 0, refunded_cents: allocation.refunded_cents + amount]

            :retained ->
              [held_cents: 0, retained_cents: allocation.retained_cents + amount]

            :converted ->
              [
                held_cents: 0,
                converted_to_credit_cents: allocation.converted_to_credit_cents + amount
              ]
          end

        allocation |> Ecto.Changeset.change(attrs) |> Repo.update!()
      end
    end)
  end

  defp restore_credit_allocations(room_ids, occurred_on) do
    from(a in CreditAllocation,
      join: l in CreditLot,
      on: l.id == a.credit_lot_id,
      where: a.room_id in ^room_ids,
      order_by: [asc: a.id],
      select: {a, l}
    )
    |> Repo.all()
    |> Enum.each(fn {allocation, lot} ->
      Repo.delete!(allocation)
      restore_credit!(lot, allocation.amount_cents, occurred_on)
    end)
  end

  defp restore_credit!(lot, amount, occurred_on) do
    lot = Repo.get!(CreditLot, lot.id)
    unrecovered = lot.unrecovered_clawback_cents || 0
    absorbed = min(amount, unrecovered)
    excess = amount - absorbed
    available = if Date.compare(lot.expires_on, occurred_on) in [:eq, :gt], do: excess, else: 0

    lot
    |> Ecto.Changeset.change(
      remaining_cents: lot.remaining_cents + available,
      unrecovered_clawback_cents: unrecovered - absorbed
    )
    |> Repo.update!()
  end

  defp consume_credit_allocations(room_ids) do
    from(a in CreditAllocation, where: a.room_id in ^room_ids)
    |> Repo.delete_all()
  end

  defp add_credit_contributions(lot, cash_allocations) do
    {_, contributions} =
      Enum.reduce(cash_allocations, {0, %{}}, fn allocation, {running_cash, contributions} ->
        next_cash = running_cash + allocation.held_cents
        entitlement = bonus_value(next_cash) - bonus_value(running_cash)

        {next_cash,
         Map.update(
           contributions,
           allocation.payment_operation_id,
           entitlement,
           &(&1 + entitlement)
         )}
      end)

    Enum.each(contributions, fn {operation_id, entitlement} ->
      if entitlement > 0 do
        Repo.insert!(%CreditLotContribution{
          credit_lot_id: lot.id,
          payment_operation_id: operation_id,
          entitlement_cents: entitlement
        })
      end
    end)
  end

  defp bonus_value(cash), do: cash + round_percentage(cash, 10, 100)

  defp chargeable_amount(allocation) do
    allocation.held_cents + allocation.refunded_cents + allocation.retained_cents +
      allocation.converted_to_credit_cents
  end

  defp validate_common(operation) do
    cond do
      validate_operation_id(operation) != :ok -> {:error, "invalid_operation"}
      not Map.has_key?(operation, "occurred_on") -> {:error, "invalid_operation"}
      true -> :ok
    end
  end

  defp cancellation_refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      method when method in @valid_refund_methods -> {:ok, method}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp validate_operation_id(operation) do
    if valid_identifier?(operation_id(operation)), do: :ok, else: {:error, "invalid_operation"}
  end

  defp validate_payment_identifier(value) do
    if valid_identifier?(value), do: :ok, else: {:error, "invalid_operation"}
  end

  defp validate_identifiers(operation, keys) do
    if Enum.all?(keys, &valid_identifier?(operation[&1])),
      do: :ok,
      else: {:error, "invalid_operation"}
  end

  defp valid_identifier?(value), do: is_binary(value) and byte_size(value) > 0
  defp usable_rate?(value), do: is_integer(value) and value > 0
  defp usable_amount?(value), do: is_integer(value) and value > 0
  defp valid_date?(value), do: match?({:ok, _date}, parse_date(value))
  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_value), do: {:error, :invalid_date}

  defp transaction_result({:ok, result}), do: result
  defp transaction_result({:error, :group_insert_failed}), do: raise("could not insert group")

  defp claim_operation(operation) do
    attrs = %{
      operation_id: operation_id(operation),
      type: stored_type(operation["type"]),
      payload: operation,
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    case Repo.insert_all(Operation, [attrs],
           on_conflict: :nothing,
           conflict_target: [:operation_id]
         ) do
      {1, _} -> {:new, Repo.get_by!(Operation, operation_id: operation_id(operation))}
      {0, _} -> {:existing, Repo.get_by!(Operation, operation_id: operation_id(operation))}
    end
  end

  defp remember_operation!(record, result) do
    result = json_result(result)

    record
    |> Ecto.Changeset.change(result: result)
    |> Repo.update!()

    result
  end

  defp stored_type(type) when is_binary(type), do: type
  defp stored_type(_type), do: nil
  defp json_result(result), do: result |> Jason.encode!() |> Jason.decode!()
  defp with_write_lock(fun), do: :global.trans({__MODULE__, :write}, fun)

  defp applied(operation, fields),
    do: Map.merge(%{operation_id: operation_id(operation), status: "applied"}, fields)

  defp applied_result?(%{status: "applied"}), do: true
  defp applied_result?(_result), do: false

  defp rejected(operation, code),
    do: %{operation_id: operation_id(operation), status: "rejected", code: code}

  defp operation_id(operation) when is_map(operation), do: operation["operation_id"]
  defp operation_id(_operation), do: nil

  defp outstanding(%{deposit_due_cents: due, deposit_paid_cents: paid}), do: due - paid

  defp round_percentage(amount, numerator, denominator),
    do: div(amount * numerator + div(denominator, 2), denominator)

  defp update_group_with_totals!(group, attrs) do
    if group.status == "cancelled" do
      update_group!(group, attrs)
    else
      totals = Groups.totals(group.group_id)

      update_group!(
        group,
        Map.merge(
          %{
            lodging_total_cents: totals.lodging_total_cents,
            deposit_due_cents: totals.deposit_due_cents,
            deposit_paid_cents: totals.deposit_paid_cents,
            cash_paid_cents: totals.cash_paid_cents,
            credit_paid_cents: totals.credit_paid_cents
          },
          attrs
        )
      )
    end
  end

  defp update_changed_groups!(addressed_group_id, changed_group_ids) do
    changed_group_ids
    |> MapSet.put(addressed_group_id)
    |> Enum.sort()
    |> Enum.reduce(%{}, fn group_id, updated_groups ->
      group = Repo.get!(Group, group_id)
      Map.put(updated_groups, group_id, update_group_with_totals!(group, %{}))
    end)
  end

  defp update_group!(group, attrs) do
    group
    |> Ecto.Changeset.change(Map.put(attrs, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp check_expected_revision(operation, group),
    do: check_expected_revision(operation, "expected_revision", group)

  defp check_expected_revision(operation, key, group) do
    if Map.has_key?(operation, key) and operation[key] != group.revision do
      {:error,
       %{
         operation_id: operation_id(operation),
         status: "rejected",
         code: "stale_revision",
         group_id: group.group_id,
         expected_revision: operation[key],
         actual_revision: group.revision
       }}
    else
      :ok
    end
  end

  defp serialize_date(nil), do: nil
  defp serialize_date(date), do: Date.to_iso8601(date)

  defp rejected_with_group(operation, code, group_id),
    do: Map.put(rejected(operation, code), :group_id, group_id)

  defp next_allocation_order! do
    Repo.insert!(%AllocationSequence{}).id
  end
end
