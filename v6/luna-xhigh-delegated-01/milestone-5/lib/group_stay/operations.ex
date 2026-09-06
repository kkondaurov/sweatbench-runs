defmodule GroupStay.Operations do
  @moduledoc "Applies partner operations in order and returns one outcome per operation."

  import Ecto.Query

  alias GroupStay.{CashPayment, Credit, Groups, Ledger, Repo}
  alias GroupStay.Credit.Allocation, as: CreditAllocation
  alias GroupStay.Groups.{Group, Room, RoomAllocation}
  alias GroupStay.Operations.Operation

  @flexible "flexible"
  @advance_purchase "advance_purchase"
  @policy_cutover ~D[2027-01-01]
  @max_sqlite_integer 9_223_372_036_854_775_807

  @type result :: map()

  def process_batch(operations) when is_list(operations), do: Enum.map(operations, &process/1)

  def process(operation) when not is_map(operation), do: rejected(nil, "invalid_operation")

  def process(operation) do
    operation_id = value(operation, "operation_id")

    if valid_identifier?(operation_id) do
      process_durably(operation, operation_id)
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  def get_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil -> nil
      operation -> Jason.decode!(operation.result_json)
    end
  end

  def get_result(_operation_id), do: nil

  def reconcile_payment(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(Operation, operation_id: payment_operation_id) do
      nil ->
        {:error, :operation_not_found}

      operation ->
        case Repo.get(CashPayment, payment_operation_id) do
          %CashPayment{} = payment when operation.type == "record_cash_payment" ->
            result = Jason.decode!(operation.result_json)

            if result["status"] == "applied" do
              statement = %{
                payment_operation_id: payment_operation_id,
                original_group_id: payment.group_id,
                recorded_cents: payment.recorded_cents,
                held_cents: payment.held_cents,
                refunded_cents: payment.refunded_cents,
                retained_cents: payment.retained_cents,
                converted_to_credit_cents: payment.converted_to_credit_cents,
                reduced_cents: payment.reduced_cents,
                charged_back_cents: payment.charged_back_cents
              }

              statement =
                if payment.transfer_participated do
                  Map.put(statement, :held_by_group, held_by_group(payment_operation_id))
                else
                  statement
                end

              {:ok, statement}
            else
              {:error, :payment_not_reconcilable}
            end

          _ ->
            {:error, :payment_not_reconcilable}
        end
    end
  end

  def reconcile_payment(_payment_operation_id), do: {:error, :operation_not_found}

  defp process_durably(operation, operation_id) do
    payload_json = Jason.encode!(canonical_json(operation))

    with_write_lock(fn ->
      process_durably_with_retries(operation, operation_id, payload_json, 0)
    end)
  end

  defp process_durably_with_retries(operation, operation_id, payload_json, attempt) do
    transaction =
      Repo.transaction(
        fn ->
          case Repo.get_by(Operation, operation_id: operation_id) do
            nil ->
              result = process_uncached(operation, operation_id)
              persist_operation!(operation, operation_id, payload_json, result)
              result

            stored_operation ->
              if stored_operation.payload_json == payload_json do
                Jason.decode!(stored_operation.result_json)
              else
                rejected(operation_id, "operation_id_conflict")
              end
          end
        end,
        mode: :immediate
      )

    case transaction do
      {:ok, result} ->
        result

      {:error, {:retry, _reason}} when attempt < 10 ->
        process_durably_with_retries(operation, operation_id, payload_json, attempt + 1)

      {:error, {:retry, reason}} ->
        raise "unable to apply operation after retries: #{inspect(reason)}"
    end
  end

  defp process_uncached(operation, operation_id) do
    case value(operation, "type") do
      "open_group" ->
        process_open(operation, operation_id)

      type
      when type in [
             "record_cash_payment",
             "reschedule_group",
             "cancel_group",
             "cancel_rooms",
             "apply_hotel_credit"
           ] ->
        process_existing_group_operation(operation, operation_id, type)

      "transfer_deposit" ->
        process_transfer(operation, operation_id)

      "reduce_cash_payment" ->
        process_payment_correction(operation, operation_id, :reduce)

      "charge_back_payment" ->
        process_payment_correction(operation, operation_id, :charge_back)

      _ ->
        rejected(operation_id, "invalid_operation")
    end
  end

  defp process_open(operation, operation_id) do
    group_id = value(operation, "group_id")

    if valid_identifier?(group_id) do
      case Repo.get(Group, group_id) do
        %Group{} -> rejected(operation_id, "group_already_exists")
        nil -> apply_open(operation, operation_id, group_id)
      end
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp process_existing_group_operation(operation, operation_id, type) do
    group_id = value(operation, "group_id")

    if valid_identifier?(group_id) do
      case Repo.get(Group, group_id) do
        nil ->
          rejected(operation_id, "group_not_found", group_id: group_id)

        group ->
          case stale_revision(operation, group) do
            :ok -> apply_existing_group_operation(operation, operation_id, type, group)
            stale -> rejected(operation_id, "stale_revision", stale)
          end
      end
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp held_by_group(payment_operation_id) do
    payment_operation_id
    |> cash_allocations_for_payment()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {group_id, amounts} ->
      %{group_id: group_id, amount_cents: Enum.sum(amounts)}
    end)
    |> Enum.sort_by(& &1.group_id)
  end

  defp cash_allocations_for_payment(payment_operation_id) do
    Repo.all(
      from allocation in RoomAllocation,
        join: group in Group,
        on: group.group_id == allocation.group_id,
        join: room in Room,
        on: room.group_id == allocation.group_id and room.room_id == allocation.room_id,
        where:
          allocation.operation_id == ^payment_operation_id and
            allocation.funding_type == "cash" and
            group.status == ^Groups.active_status() and
            room.status == ^Groups.active_status(),
        select: {allocation.group_id, allocation.amount_cents}
    )
  end

  defp process_transfer(operation, operation_id) do
    source_group_id = value(operation, "source_group_id")
    destination_group_id = value(operation, "destination_group_id")

    if valid_identifier?(source_group_id) and valid_identifier?(destination_group_id) do
      case Repo.get(Group, source_group_id) do
        nil ->
          rejected(operation_id, "group_not_found", group_id: source_group_id)

        source_group ->
          case Repo.get(Group, destination_group_id) do
            nil ->
              rejected(operation_id, "group_not_found", group_id: destination_group_id)

            destination_group ->
              case stale_revision(operation, source_group, "expected_revision") do
                :ok ->
                  case stale_revision(
                         operation,
                         destination_group,
                         "destination_expected_revision"
                       ) do
                    :ok ->
                      apply_transfer(operation, operation_id, source_group, destination_group)

                    stale ->
                      rejected(operation_id, "stale_revision", stale)
                  end

                stale ->
                  rejected(operation_id, "stale_revision", stale)
              end
          end
      end
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp process_payment_correction(operation, operation_id, kind) do
    target_id = value(operation, "payment_operation_id")

    if valid_identifier?(target_id) do
      case Repo.get_by(Operation, operation_id: target_id) do
        nil ->
          rejected(operation_id, "operation_not_found")

        target_operation ->
          payment = Repo.get(CashPayment, target_id)

          if target_operation.type == "record_cash_payment" and
               is_map(payment) and applied_result?(target_operation) do
            group = Repo.get(Group, payment.group_id)

            if group == nil do
              correction_rejection(operation_id, kind)
            else
              case stale_revision(operation, group) do
                :ok ->
                  if kind == :reduce do
                    apply_reduction(operation, operation_id, group, payment)
                  else
                    apply_charge_back(operation, operation_id, group, payment)
                  end

                stale ->
                  rejected(operation_id, "stale_revision", stale)
              end
            end
          else
            correction_rejection(operation_id, kind)
          end
      end
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp correction_rejection(operation_id, :reduce),
    do: rejected(operation_id, "payment_not_reducible")

  defp correction_rejection(operation_id, :charge_back),
    do: rejected(operation_id, "payment_not_chargeable")

  defp apply_open(operation, operation_id, group_id) do
    with {:ok, occurred_on} <- parse_date(value(operation, "occurred_on")),
         {:ok, arrival_on} <- parse_date(value(operation, "arrival_on")),
         {:ok, departure_on} <- parse_date(value(operation, "departure_on")),
         :ok <- validate_stay(arrival_on, departure_on),
         {:ok, rate_plan} <- validate_rate_plan(value(operation, "rate_plan")),
         {:ok, rooms} <- validate_rooms(value(operation, "rooms")),
         {:ok, room_values} <-
           calculate_room_values(rooms, Date.diff(departure_on, arrival_on), rate_plan),
         {:ok, lodging_total_cents} <- sum_values(room_values, :lodging_total_cents),
         {:ok, deposit_due_cents} <- sum_values(room_values, :deposit_due_cents) do
      guest_id = value(operation, "guest_id")
      property_id = value(operation, "property_id")

      if valid_identifier?(guest_id) and valid_identifier?(property_id) do
        Repo.insert!(%Group{
          group_id: group_id,
          guest_id: guest_id,
          property_id: property_id,
          booked_on: occurred_on,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: rate_plan,
          policy_version: policy_version_for(rate_plan, occurred_on),
          status: Groups.active_status(),
          revision: 1,
          lodging_total_cents: lodging_total_cents,
          deposit_due_cents: deposit_due_cents,
          deposit_paid_cents: 0,
          cash_paid_cents: 0,
          credit_paid_cents: 0
        })

        Enum.each(Enum.with_index(room_values), fn {room, position} ->
          Repo.insert!(%Room{
            group_id: group_id,
            position: position,
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            status: Groups.active_status(),
            lodging_total_cents: room.lodging_total_cents,
            deposit_due_cents: room.deposit_due_cents,
            cash_paid_cents: 0,
            credit_paid_cents: 0
          })
        end)

        %{
          operation_id: operation_id,
          status: "applied",
          group_id: group_id,
          deposit_due_cents: deposit_due_cents,
          revision: 1
        }
      else
        rejected(operation_id, "invalid_operation")
      end
    else
      {:error, :invalid_stay} -> rejected(operation_id, "invalid_stay")
      {:error, :invalid_rooms} -> rejected(operation_id, "invalid_rooms")
      {:error, :invalid_rate_plan} -> rejected(operation_id, "invalid_rate_plan")
      {:error, :overflow} -> rejected(operation_id, "invalid_rooms")
    end
  end

  defp apply_existing_group_operation(operation, operation_id, "record_cash_payment", group) do
    if Groups.active?(group),
      do: apply_payment(operation, operation_id, group),
      else: inactive(operation_id, group)
  end

  defp apply_existing_group_operation(operation, operation_id, "reschedule_group", group) do
    if Groups.active?(group),
      do: apply_reschedule(operation, operation_id, group),
      else: inactive(operation_id, group)
  end

  defp apply_existing_group_operation(operation, operation_id, "cancel_group", group) do
    if Groups.active?(group),
      do: apply_cancellation(operation, operation_id, group),
      else: inactive(operation_id, group)
  end

  defp apply_existing_group_operation(operation, operation_id, "cancel_rooms", group) do
    if Groups.active?(group),
      do: apply_selected_cancellation(operation, operation_id, group),
      else: inactive(operation_id, group)
  end

  defp apply_existing_group_operation(operation, operation_id, "apply_hotel_credit", group) do
    if Groups.active?(group),
      do: apply_hotel_credit(operation, operation_id, group),
      else: inactive(operation_id, group)
  end

  defp apply_transfer(operation, operation_id, source_group, destination_group) do
    cond do
      source_group.group_id == destination_group.group_id or
          source_group.guest_id != destination_group.guest_id ->
        rejected(operation_id, "invalid_transfer")

      not Groups.active?(source_group) ->
        rejected(operation_id, "group_not_active", group_id: source_group.group_id)

      not Groups.active?(destination_group) ->
        rejected(operation_id, "group_not_active", group_id: destination_group.group_id)

      not usable_amount?(value(operation, "amount_cents")) ->
        rejected(operation_id, "invalid_amount")

      true ->
        source_rooms = Groups.rooms_for(source_group.group_id)
        destination_rooms = Groups.rooms_for(destination_group.group_id)
        source = %{source_group | rooms: source_rooms}
        destination = %{destination_group | rooms: destination_rooms}
        amount_cents = value(operation, "amount_cents")
        source_held_cents = held_funding(source)
        destination_outstanding_cents = Groups.totals(destination).outstanding_deposit_cents

        cond do
          amount_cents > source_held_cents ->
            rejected(operation_id, "transfer_exceeds_held_funding")

          amount_cents > destination_outstanding_cents ->
            rejected(operation_id, "transfer_exceeds_outstanding")

          true ->
            {segments, transferred_cash_payment_ids} =
              remove_transfer_source_funding!(source, amount_cents)

            add_transfer_destination_funding!(destination, segments)
            mark_transfer_participation!(transferred_cash_payment_ids)

            source_revision = source.revision + 1
            destination_revision = destination.revision + 1
            update_group_totals!(source, source_revision)
            update_group_totals!(destination, destination_revision)

            updated_source = %{source | rooms: Groups.rooms_for(source.group_id)}
            updated_destination = %{destination | rooms: Groups.rooms_for(destination.group_id)}

            %{
              operation_id: operation_id,
              status: "applied",
              source_group_id: source.group_id,
              destination_group_id: destination.group_id,
              amount_cents: amount_cents,
              source_outstanding_deposit_cents:
                Groups.totals(updated_source).outstanding_deposit_cents,
              destination_outstanding_deposit_cents:
                Groups.totals(updated_destination).outstanding_deposit_cents,
              source_revision: source_revision,
              destination_revision: destination_revision
            }
        end
    end
  end

  defp held_funding(group) do
    group
    |> held_room_allocations()
    |> Enum.reduce(0, &(&1.amount_cents + &2))
  end

  defp held_room_allocations(group) do
    Repo.all(
      from allocation in RoomAllocation,
        join: room in Room,
        on: room.group_id == allocation.group_id and room.room_id == allocation.room_id,
        where:
          allocation.group_id == ^group.group_id and
            room.status == ^Groups.active_status() and allocation.amount_cents > 0,
        order_by: [desc: allocation.id]
    )
  end

  defp remove_transfer_source_funding!(group, amount_cents) do
    {remaining, segments, cash_payment_ids} =
      Enum.reduce_while(held_room_allocations(group), {amount_cents, [], []}, fn allocation,
                                                                                 {remaining,
                                                                                  segments,
                                                                                  cash_ids} ->
        take = min(remaining, allocation.amount_cents)
        remove_source_allocation!(allocation, take)

        segment = %{allocation | amount_cents: take}

        cash_ids =
          if allocation.funding_type == "cash",
            do: [allocation.operation_id | cash_ids],
            else: cash_ids

        next = remaining - take

        if next == 0 do
          {:halt, {0, [segment | segments], cash_ids}}
        else
          {:cont, {next, [segment | segments], cash_ids}}
        end
      end)

    if remaining != 0, do: raise("transfer allocation invariant violated")

    {Enum.reverse(segments), Enum.uniq(Enum.reject(cash_payment_ids, &is_nil/1))}
  end

  defp remove_source_allocation!(allocation, amount_cents) do
    room =
      Repo.one!(
        from room in Room,
          where: room.group_id == ^allocation.group_id and room.room_id == ^allocation.room_id
      )

    field = if allocation.funding_type == "cash", do: :cash_paid_cents, else: :credit_paid_cents

    Repo.update!(
      Ecto.Changeset.change(room, [{field, (Map.get(room, field) || 0) - amount_cents}])
    )

    if allocation.amount_cents == amount_cents do
      Repo.delete!(allocation)
    else
      Repo.update!(
        Ecto.Changeset.change(allocation, amount_cents: allocation.amount_cents - amount_cents)
      )
    end

    if allocation.funding_type == "credit" do
      reduce_credit_allocation!(allocation.credit_allocation_id, amount_cents)
    end
  end

  defp reduce_credit_allocation!(nil, _amount_cents), do: :ok

  defp reduce_credit_allocation!(credit_allocation_id, amount_cents) do
    credit_allocation = Repo.get!(CreditAllocation, credit_allocation_id)

    if credit_allocation.amount_cents == amount_cents do
      Repo.delete!(credit_allocation)
    else
      Repo.update!(
        Ecto.Changeset.change(credit_allocation,
          amount_cents: credit_allocation.amount_cents - amount_cents
        )
      )
    end
  end

  defp add_transfer_destination_funding!(group, segments) do
    rooms = Groups.active_rooms(group)

    {_rooms, remaining} =
      Enum.reduce(segments, {rooms, 0}, fn segment, {rooms, remaining_total} ->
        {rooms, remaining} = add_transfer_segment!(group.group_id, rooms, segment)
        {rooms, remaining_total + remaining}
      end)

    if remaining != 0, do: raise("transfer destination allocation invariant violated")
  end

  defp add_transfer_segment!(group_id, rooms, segment) do
    destination_credit_allocation_id =
      if segment.funding_type == "credit" do
        Repo.insert!(%CreditAllocation{
          group_id: group_id,
          lot_id: segment.lot_id,
          amount_cents: segment.amount_cents
        }).id
      end

    {rooms, remaining} =
      Enum.map_reduce(rooms, segment.amount_cents, fn room, remaining ->
        capacity = Groups.room_outstanding(room)
        take = min(remaining, capacity)

        if take > 0 do
          Repo.insert!(%RoomAllocation{
            group_id: group_id,
            room_id: room.room_id,
            funding_type: segment.funding_type,
            operation_id: segment.operation_id,
            amount_cents: take,
            lot_id: segment.lot_id,
            credit_allocation_id: destination_credit_allocation_id
          })

          field =
            if segment.funding_type == "cash", do: :cash_paid_cents, else: :credit_paid_cents

          updated_room =
            Repo.update!(
              Ecto.Changeset.change(room, [{field, (Map.get(room, field) || 0) + take}])
            )

          {updated_room, remaining - take}
        else
          {room, remaining}
        end
      end)

    {rooms, remaining}
  end

  defp mark_transfer_participation!([]), do: :ok

  defp mark_transfer_participation!(payment_operation_ids) do
    Repo.update_all(
      from(payment in CashPayment, where: payment.operation_id in ^payment_operation_ids),
      set: [transfer_participated: true]
    )

    :ok
  end

  defp inactive(operation_id, group),
    do: rejected(operation_id, "group_not_active", group_id: group.group_id)

  defp apply_payment(operation, operation_id, group) do
    with {:ok, _occurred_on} <- parse_date(value(operation, "occurred_on")) do
      amount_cents = value(operation, "amount_cents")
      totals = Groups.totals(group)

      cond do
        not usable_amount?(amount_cents) ->
          rejected(operation_id, "invalid_amount", group_id: group.group_id)

        amount_cents > totals.outstanding_deposit_cents ->
          rejected(operation_id, "payment_exceeds_outstanding", group_id: group.group_id)

        true ->
          case Ledger.validate_cash_addition(amount_cents) do
            :ok ->
              Ledger.add_cash(amount_cents)
              allocate_cash(group.group_id, operation_id, amount_cents)

              Repo.insert!(%CashPayment{
                operation_id: operation_id,
                group_id: group.group_id,
                recorded_cents: amount_cents,
                held_cents: amount_cents,
                refunded_cents: 0,
                retained_cents: 0,
                converted_to_credit_cents: 0,
                reduced_cents: 0,
                charged_back_cents: 0
              })

              revision = group.revision + 1
              update_group_totals!(group, revision)
              new_totals = Groups.totals(%{group | rooms: Groups.rooms_for(group.group_id)})

              %{
                operation_id: operation_id,
                status: "applied",
                group_id: group.group_id,
                amount_cents: amount_cents,
                outstanding_deposit_cents: new_totals.outstanding_deposit_cents,
                revision: revision
              }

            {:error, :overflow} ->
              rejected(operation_id, "invalid_amount", group_id: group.group_id)
          end
      end
    else
      {:error, :invalid_stay} -> rejected(operation_id, "invalid_stay", group_id: group.group_id)
    end
  end

  defp apply_reschedule(operation, operation_id, group) do
    with {:ok, occurred_on} <- parse_date(value(operation, "occurred_on")),
         {:ok, new_arrival_on} <- parse_date(value(operation, "new_arrival_on")),
         :ok <- validate_reschedule(occurred_on, new_arrival_on) do
      stay_length = Date.diff(group.departure_on, group.arrival_on)
      new_departure_on = Date.add(new_arrival_on, stay_length)
      revision = group.revision + 1

      case update_group(group,
             arrival_on: new_arrival_on,
             departure_on: new_departure_on,
             revision: revision
           ) do
        :ok ->
          %{
            operation_id: operation_id,
            status: "applied",
            group_id: group.group_id,
            new_arrival_on: Date.to_iso8601(new_arrival_on),
            new_departure_on: Date.to_iso8601(new_departure_on),
            policy_version: Groups.policy_version(group),
            refundable_until:
              format_date(Groups.refundable_until(%{group | arrival_on: new_arrival_on})),
            revision: revision
          }

        {:retry, reason} ->
          Repo.rollback({:retry, reason})
      end
    else
      {:error, :invalid_stay} -> rejected(operation_id, "invalid_stay", group_id: group.group_id)
    end
  end

  defp apply_hotel_credit(operation, operation_id, group) do
    with {:ok, occurred_on} <- parse_date(value(operation, "occurred_on")) do
      amount_cents = value(operation, "amount_cents")
      totals = Groups.totals(group)

      cond do
        not usable_amount?(amount_cents) ->
          rejected(operation_id, "invalid_amount", group_id: group.group_id)

        amount_cents > totals.outstanding_deposit_cents ->
          rejected(operation_id, "payment_exceeds_outstanding", group_id: group.group_id)

        true ->
          case Credit.consume(group.guest_id, group.group_id, amount_cents, occurred_on) do
            {:error, :insufficient_credit} ->
              rejected(operation_id, "insufficient_credit", group_id: group.group_id)

            {:ok, credit_segments} ->
              allocate_credit(group.group_id, operation_id, amount_cents, credit_segments)
              revision = group.revision + 1
              update_group_totals!(group, revision)
              :ok = Ledger.refresh_credit_liability(occurred_on)
              new_totals = Groups.totals(%{group | rooms: Groups.rooms_for(group.group_id)})

              %{
                operation_id: operation_id,
                status: "applied",
                group_id: group.group_id,
                amount_cents: amount_cents,
                outstanding_deposit_cents: new_totals.outstanding_deposit_cents,
                revision: revision
              }
          end
      end
    else
      {:error, :invalid_stay} -> rejected(operation_id, "invalid_stay", group_id: group.group_id)
    end
  end

  defp apply_cancellation(operation, operation_id, group) do
    active_rooms = Groups.active_rooms(%{group | rooms: Groups.rooms_for(group.group_id)})
    apply_room_cancellation(operation, operation_id, group, active_rooms, :full)
  end

  defp apply_selected_cancellation(operation, operation_id, group) do
    rooms = Groups.rooms_for(group.group_id)
    requested_ids = value(operation, "room_ids")

    with {:ok, selected_rooms} <- select_active_rooms(rooms, requested_ids) do
      apply_room_cancellation(operation, operation_id, group, selected_rooms, :selected)
    else
      {:error, :invalid_rooms} ->
        rejected(operation_id, "invalid_rooms", group_id: group.group_id)
    end
  end

  defp apply_room_cancellation(operation, operation_id, group, selected_rooms, mode) do
    case parse_date(value(operation, "occurred_on")) do
      {:error, :invalid_stay} ->
        rejected(operation_id, "invalid_stay", group_id: group.group_id)

      {:ok, occurred_on} ->
        refund_method = refund_method(operation)

        case validate_refund_method(refund_method) do
          {:error, :invalid_refund_method} ->
            rejected(operation_id, "invalid_refund_method", group_id: group.group_id)

          :ok ->
            refundable? = refundable?(group, occurred_on)

            if refund_method == "hotel_credit" and not refundable? do
              rejected(operation_id, "refund_method_not_available", group_id: group.group_id)
            else
              room_ids = Enum.map(selected_rooms, & &1.room_id)
              cash_allocations = room_allocations(group.group_id, room_ids, "cash")
              credit_allocations = room_allocations(group.group_id, room_ids, "credit")
              cash_cents = Enum.sum(Enum.map(cash_allocations, & &1.amount_cents))

              {refunded_cents, retained_cents, converted_cents} =
                cancellation_cash_settlement(cash_cents, refund_method, refundable?)

              credit_issued_cents =
                if refundable? and refund_method == "hotel_credit" do
                  credit_amount(cash_cents)
                else
                  {:ok, 0}
                end

              with {:ok, credit_issued_cents} <- credit_issued_cents,
                   :ok <-
                     Ledger.validate_cash_settlement(
                       refunded_cents,
                       retained_cents,
                       converted_cents
                     ),
                   :ok <-
                     validate_credit_settlement(
                       credit_allocations,
                       occurred_on,
                       refundable?,
                       credit_issued_cents
                     ) do
                contributions = credit_contributions(cash_allocations)
                settle_cash_allocations(cash_allocations, refundable?, refund_method)

                {:ok, _} =
                  Credit.settle_room_allocations(credit_allocations, occurred_on, refundable?)

                cancel_rooms!(selected_rooms)

                if update_group_after_rooms(group, selected_rooms, mode) == :retry do
                  Repo.rollback({:retry, :concurrent_update})
                end

                :ok = Ledger.settle_cash(refunded_cents, retained_cents, converted_cents)

                if credit_issued_cents > 0 do
                  Credit.issue_with_contributions(
                    group.guest_id,
                    operation_id,
                    credit_issued_cents,
                    Date.add(occurred_on, 366),
                    contributions
                  )
                end

                :ok = Ledger.refresh_credit_liability(occurred_on)
                revision = group.revision + 1

                result = %{
                  operation_id: operation_id,
                  status: "applied",
                  group_id: group.group_id,
                  refunded_cents: refunded_cents,
                  retained_cents: retained_cents,
                  credit_issued_cents: credit_issued_cents,
                  revision: revision
                }

                if mode == :selected do
                  Map.put(result, :cancelled_room_ids, room_ids)
                  |> reorder_cancelled_result()
                else
                  result
                end
              else
                {:error, :overflow} ->
                  rejected(operation_id, "invalid_operation", group_id: group.group_id)
              end
            end
        end
    end
  end

  defp reorder_cancelled_result(result), do: result

  defp validate_credit_settlement(credit_allocations, occurred_on, refundable?, issued) do
    Credit.liability_after_room_settlement(credit_allocations, occurred_on, refundable?, issued)
    |> Ledger.validate_credit_liability()
  end

  defp settle_cash_allocations(allocations, refundable?, refund_method) do
    disposition =
      cond do
        refundable? and refund_method == "cash" -> :refunded
        refundable? and refund_method == "hotel_credit" -> :converted
        true -> :retained
      end

    Enum.each(allocations, fn allocation ->
      if allocation.operation_id do
        payment = Repo.get!(CashPayment, allocation.operation_id)

        attrs = [held_cents: payment.held_cents - allocation.amount_cents]

        attrs =
          case disposition do
            :refunded ->
              Keyword.put(
                attrs,
                :refunded_cents,
                payment.refunded_cents + allocation.amount_cents
              )

            :retained ->
              Keyword.put(
                attrs,
                :retained_cents,
                payment.retained_cents + allocation.amount_cents
              )

            :converted ->
              Keyword.put(
                attrs,
                :converted_to_credit_cents,
                payment.converted_to_credit_cents + allocation.amount_cents
              )
          end

        Repo.update!(Ecto.Changeset.change(payment, attrs))
      end

      Repo.delete!(allocation)
    end)
  end

  defp apply_reduction(operation, operation_id, group, payment) do
    amount_cents = value(operation, "amount_cents")

    cond do
      not usable_amount?(amount_cents) ->
        rejected(operation_id, "invalid_amount")

      payment.held_cents <= 0 ->
        rejected(operation_id, "payment_not_reducible")

      amount_cents > payment.held_cents ->
        rejected(operation_id, "reduction_exceeds_held_cash")

      true ->
        case Ledger.validate_cash_reduction(amount_cents) do
          {:error, :overflow} ->
            rejected(operation_id, "invalid_operation")

          :ok ->
            affected_group_ids = remove_cash_allocations(payment.operation_id, amount_cents)
            Ledger.reduce_cash(amount_cents)

            Repo.update!(
              Ecto.Changeset.change(payment,
                held_cents: payment.held_cents - amount_cents,
                reduced_cents: payment.reduced_cents + amount_cents
              )
            )

            revision = update_groups_after_cash_change!(group, affected_group_ids)
            totals = Groups.totals(%{group | rooms: Groups.rooms_for(group.group_id)})

            %{
              operation_id: operation_id,
              status: "applied",
              payment_operation_id: payment.operation_id,
              group_id: group.group_id,
              amount_cents: amount_cents,
              outstanding_deposit_cents: totals.outstanding_deposit_cents,
              revision: revision
            }
        end
    end
  end

  defp apply_charge_back(_operation, operation_id, group, payment) do
    cond do
      payment.charged_back_cents > 0 or payment.reduced_cents == payment.recorded_cents ->
        rejected(operation_id, "payment_not_chargeable")

      true ->
        held = payment.held_cents
        refunded = payment.refunded_cents
        retained = payment.retained_cents
        converted = payment.converted_to_credit_cents

        case Ledger.validate_charge_back_cash(held, refunded, retained, converted) do
          {:error, :overflow} ->
            rejected(operation_id, "invalid_operation")

          :ok ->
            affected_group_ids = remove_cash_allocations(payment.operation_id, held)
            Ledger.charge_back_cash(held, refunded, retained, converted)
            Credit.claw_back_payment(payment.operation_id)

            Repo.update!(
              Ecto.Changeset.change(payment,
                held_cents: 0,
                refunded_cents: 0,
                retained_cents: 0,
                converted_to_credit_cents: 0,
                charged_back_cents:
                  payment.charged_back_cents + held + refunded + retained + converted
              )
            )

            revision = update_groups_after_cash_change!(group, affected_group_ids)
            totals = Groups.totals(%{group | rooms: Groups.rooms_for(group.group_id)})
            charged_back_cents = held + refunded + retained + converted

            %{
              operation_id: operation_id,
              status: "applied",
              payment_operation_id: payment.operation_id,
              group_id: group.group_id,
              charged_back_cents: charged_back_cents,
              outstanding_deposit_cents: totals.outstanding_deposit_cents,
              revision: revision
            }
        end
    end
  end

  defp remove_cash_allocations(_payment_operation_id, 0), do: []

  defp remove_cash_allocations(payment_operation_id, amount_cents) do
    allocations =
      Repo.all(
        from allocation in RoomAllocation,
          where:
            allocation.operation_id == ^payment_operation_id and
              allocation.funding_type == "cash",
          order_by: [desc: allocation.id]
      )

    {remaining, affected_group_ids} =
      Enum.reduce_while(allocations, {amount_cents, []}, fn allocation,
                                                            {remaining, affected_group_ids} ->
        take = min(remaining, allocation.amount_cents)

        room =
          Repo.one!(
            from room in Room,
              where: room.group_id == ^allocation.group_id and room.room_id == ^allocation.room_id
          )

        Repo.update!(Ecto.Changeset.change(room, cash_paid_cents: room.cash_paid_cents - take))

        if take == allocation.amount_cents do
          Repo.delete!(allocation)
        else
          Repo.update!(
            Ecto.Changeset.change(allocation, amount_cents: allocation.amount_cents - take)
          )
        end

        next = remaining - take
        affected_group_ids = [allocation.group_id | affected_group_ids]

        if next == 0,
          do: {:halt, {0, affected_group_ids}},
          else: {:cont, {next, affected_group_ids}}
      end)

    if remaining != 0, do: raise("cash allocation invariant violated")

    Enum.uniq(affected_group_ids)
  end

  defp update_groups_after_cash_change!(addressed_group, affected_group_ids) do
    group_ids = Enum.uniq([addressed_group.group_id | affected_group_ids])

    Enum.each(group_ids, fn group_id ->
      group =
        if group_id == addressed_group.group_id,
          do: addressed_group,
          else: Repo.get!(Group, group_id)

      update_group_totals!(group, group.revision + 1)
    end)

    addressed_group.revision + 1
  end

  defp update_group_after_rooms(group, _selected_rooms, _mode) do
    rooms = Groups.rooms_for(group.group_id)
    active? = Enum.any?(rooms, &Groups.active_room?/1)
    status = if active?, do: Groups.active_status(), else: Groups.cancelled_status()
    update_group_totals!(group, group.revision + 1, status)
  end

  defp update_group_totals!(group, revision, status \\ nil) do
    rooms = Groups.rooms_for(group.group_id)
    totals = Groups.totals(%{group | rooms: rooms})

    attrs = [
      lodging_total_cents: totals.lodging_total_cents,
      deposit_due_cents: totals.deposit_due_cents,
      deposit_paid_cents: totals.deposit_paid_cents,
      cash_paid_cents: totals.cash_paid_cents,
      credit_paid_cents: totals.credit_paid_cents,
      revision: revision
    ]

    attrs = if status, do: Keyword.put(attrs, :status, status), else: attrs

    case update_group(group, attrs) do
      :ok -> :ok
      {:retry, reason} -> Repo.rollback({:retry, reason})
    end
  end

  defp allocate_cash(group_id, operation_id, amount_cents) do
    allocate_to_rooms(group_id, operation_id, amount_cents, "cash", [])
  end

  defp allocate_credit(group_id, operation_id, amount_cents, segments) do
    allocate_to_rooms(group_id, operation_id, amount_cents, "credit", segments)
  end

  defp allocate_to_rooms(group_id, operation_id, amount_cents, funding_type, segments) do
    rooms = Groups.rooms_for(group_id) |> Enum.filter(&Groups.active_room?/1)

    {remaining, _segments} =
      Enum.reduce(rooms, {amount_cents, segments}, fn room, {remaining, segments} ->
        capacity = Groups.room_outstanding(room)
        take = min(remaining, capacity)

        if take > 0 do
          if funding_type == "cash" do
            Repo.insert!(%RoomAllocation{
              group_id: group_id,
              room_id: room.room_id,
              operation_id: operation_id,
              funding_type: "cash",
              amount_cents: take
            })

            Repo.update!(
              Ecto.Changeset.change(room, cash_paid_cents: (room.cash_paid_cents || 0) + take)
            )

            {remaining - take, segments}
          else
            {new_segments, used} =
              add_credit_segments(room, group_id, operation_id, take, segments, 0)

            Repo.update!(
              Ecto.Changeset.change(room, credit_paid_cents: (room.credit_paid_cents || 0) + used)
            )

            {remaining - used, new_segments}
          end
        else
          {remaining, segments}
        end
      end)

    if remaining != 0, do: raise("room allocation invariant violated")
  end

  defp add_credit_segments(_room, _group_id, _operation_id, 0, segments, used),
    do: {segments, used}

  defp add_credit_segments(room, group_id, operation_id, amount, [segment | rest], used) do
    take = min(amount, segment.amount_cents)

    Repo.insert!(%RoomAllocation{
      group_id: group_id,
      room_id: room.room_id,
      operation_id: operation_id,
      funding_type: "credit",
      amount_cents: take,
      lot_id: segment.lot_id,
      credit_allocation_id: segment.credit_allocation_id
    })

    segment = %{segment | amount_cents: segment.amount_cents - take}
    rest = if segment.amount_cents == 0, do: rest, else: [segment | rest]
    add_credit_segments(room, group_id, operation_id, amount - take, rest, used + take)
  end

  defp room_allocations(group_id, room_ids, funding_type) do
    Repo.all(
      from allocation in RoomAllocation,
        where:
          allocation.group_id == ^group_id and allocation.room_id in ^room_ids and
            allocation.funding_type == ^funding_type,
        order_by: [asc: allocation.id]
    )
  end

  defp cancel_rooms!(rooms) do
    Enum.each(rooms, fn room ->
      Repo.update!(Ecto.Changeset.change(room, status: Groups.cancelled_status()))
    end)
  end

  defp select_active_rooms(rooms, room_ids) when is_list(room_ids) and room_ids != [] do
    valid? =
      Enum.all?(room_ids, &valid_identifier?/1) and
        length(room_ids) == length(Enum.uniq(room_ids))

    if valid? do
      selected =
        Enum.filter(rooms, fn room -> room.room_id in room_ids and Groups.active_room?(room) end)

      if length(selected) == length(room_ids), do: {:ok, selected}, else: {:error, :invalid_rooms}
    else
      {:error, :invalid_rooms}
    end
  end

  defp select_active_rooms(_rooms, _room_ids), do: {:error, :invalid_rooms}

  defp credit_contributions(allocations) do
    allocations
    |> Enum.reduce([], fn allocation, contributions ->
      source = allocation.operation_id

      case Enum.find_index(contributions, &(elem(&1, 0) == source)) do
        nil ->
          contributions ++ [{source, allocation.amount_cents}]

        index ->
          List.update_at(contributions, index, fn {id, amount} ->
            {id, amount + allocation.amount_cents}
          end)
      end
    end)
    |> Enum.map_reduce(0, fn {payment_operation_id, principal}, previous_principal ->
      running = previous_principal + principal

      entitlement =
        running + round_percentage(running, 10, 100) -
          (previous_principal + round_percentage(previous_principal, 10, 100))

      {%{payment_operation_id: payment_operation_id, amount_cents: entitlement}, running}
    end)
    |> elem(0)
  end

  defp cancellation_cash_settlement(cash, "cash", true), do: {cash, 0, 0}
  defp cancellation_cash_settlement(cash, "hotel_credit", true), do: {0, 0, cash}
  defp cancellation_cash_settlement(cash, _method, false), do: {0, cash, 0}

  defp credit_amount(0), do: {:ok, 0}

  defp credit_amount(cash_cents) do
    safe_add(cash_cents, round_percentage(cash_cents, 10, 100))
  end

  defp refundable?(group, occurred_on) do
    case Groups.refundable_until(group) do
      nil -> false
      refundable_until -> Date.compare(occurred_on, refundable_until) != :gt
    end
  end

  defp refund_method(operation) do
    case fetch(operation, "refund_method") do
      :missing -> "cash"
      value -> value
    end
  end

  defp validate_refund_method(method) when method in ["cash", "hotel_credit"], do: :ok
  defp validate_refund_method(_method), do: {:error, :invalid_refund_method}

  defp stale_revision(operation, group, key \\ "expected_revision") do
    case fetch(operation, key) do
      :missing ->
        :ok

      expected_revision when expected_revision == group.revision ->
        :ok

      expected_revision ->
        [
          group_id: group.group_id,
          expected_revision: expected_revision,
          actual_revision: group.revision
        ]
    end
  end

  defp validate_stay(%Date{} = arrival_on, %Date{} = departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt, do: :ok, else: {:error, :invalid_stay}
  end

  defp validate_stay(_, _), do: {:error, :invalid_stay}

  defp validate_reschedule(%Date{} = occurred_on, %Date{} = new_arrival_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt, do: :ok, else: {:error, :invalid_stay}
  end

  defp validate_reschedule(_, _), do: {:error, :invalid_stay}

  defp validate_rate_plan(rate_plan) when rate_plan in [@flexible, @advance_purchase],
    do: {:ok, rate_plan}

  defp validate_rate_plan(_rate_plan), do: {:error, :invalid_rate_plan}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    if Enum.all?(rooms, &is_map/1) do
      values =
        Enum.map(rooms, fn room -> {value(room, "room_id"), value(room, "nightly_rate_cents")} end)

      ids = Enum.map(values, &elem(&1, 0))

      if Enum.all?(values, fn {id, rate} -> valid_identifier?(id) and usable_amount?(rate) end) and
           length(ids) == length(Enum.uniq(ids)) do
        {:ok,
         Enum.map(values, fn {room_id, nightly_rate_cents} ->
           %{room_id: room_id, nightly_rate_cents: nightly_rate_cents}
         end)}
      else
        {:error, :invalid_rooms}
      end
    else
      {:error, :invalid_rooms}
    end
  end

  defp validate_rooms(_rooms), do: {:error, :invalid_rooms}

  defp calculate_room_values(rooms, nights, rate_plan) do
    Enum.reduce_while(rooms, {:ok, []}, fn room, {:ok, values} ->
      with {:ok, lodging} <- safe_multiply(room.nightly_rate_cents, nights),
           deposit <- deposit_amount(lodging, rate_plan),
           true <- deposit <= @max_sqlite_integer do
        {:cont,
         {:ok,
          values ++ [Map.merge(room, %{lodging_total_cents: lodging, deposit_due_cents: deposit})]}}
      else
        _ -> {:halt, {:error, :overflow}}
      end
    end)
  end

  defp sum_values(values, key) do
    Enum.reduce_while(values, {:ok, 0}, fn value, {:ok, total} ->
      case safe_add(total, Map.fetch!(value, key)) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp deposit_amount(lodging, @flexible), do: round_percentage(lodging, 20, 100)
  defp deposit_amount(lodging, @advance_purchase), do: lodging

  defp round_percentage(amount, numerator, denominator),
    do: div(amount * numerator + div(denominator, 2), denominator)

  defp usable_amount?(amount),
    do: is_integer(amount) and amount > 0 and amount <= @max_sqlite_integer

  defp valid_identifier?(identifier), do: is_binary(identifier) and byte_size(identifier) > 0

  defp parse_date(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, :invalid_stay}
    end
  end

  defp parse_date(_date), do: {:error, :invalid_stay}

  defp policy_version_for(@advance_purchase, _), do: "advance-nonrefundable"

  defp policy_version_for(@flexible, booked_on),
    do: if(Date.compare(booked_on, @policy_cutover) == :lt, do: "flex-14", else: "flex-30")

  defp format_date(nil), do: nil
  defp format_date(%Date{} = date), do: Date.to_iso8601(date)

  defp safe_multiply(left, right) do
    result = left * right
    if result <= @max_sqlite_integer, do: {:ok, result}, else: {:error, :overflow}
  end

  defp safe_add(left, right) do
    result = left + right
    if result <= @max_sqlite_integer, do: {:ok, result}, else: {:error, :overflow}
  end

  defp update_group(group, attrs) do
    query =
      from current in Group,
        where: current.group_id == ^group.group_id and current.revision == ^group.revision

    case Repo.update_all(query, set: attrs) do
      {1, _} -> :ok
      {0, _} -> {:retry, :concurrent_update}
    end
  end

  defp persist_operation!(operation, operation_id, payload_json, result) do
    Repo.insert!(%Operation{
      operation_id: operation_id,
      type: stored_type(value(operation, "type")),
      payload_json: payload_json,
      result_json: Jason.encode!(canonical_json(result))
    })
  end

  defp applied_result?(operation) do
    Jason.decode!(operation.result_json)["status"] == "applied"
  end

  defp stored_type(nil), do: nil
  defp stored_type(type) when is_binary(type), do: type
  defp stored_type(type), do: Jason.encode!(canonical_json(type))

  defp canonical_json(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      {if(is_binary(key), do: key, else: to_string(key)), canonical_json(nested_value)}
    end)
  end

  defp canonical_json(value) when is_list(value), do: Enum.map(value, &canonical_json/1)
  defp canonical_json(value), do: value

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, String.to_atom(key)))
  defp value(_map, _key), do: nil

  defp fetch(map, key) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, String.to_atom(key)) -> Map.get(map, String.to_atom(key))
      true -> :missing
    end
  end

  defp rejected(operation_id, code, extra \\ []),
    do: Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, Map.new(extra))

  defp with_write_lock(fun), do: :global.trans({GroupStay, :write_lock}, fun)
end
