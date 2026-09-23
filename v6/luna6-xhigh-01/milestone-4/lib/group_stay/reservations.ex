defmodule GroupStay.Reservations do
  import Ecto.Query

  alias GroupStay.{
    Repo,
    Reservation,
    PartnerOperation,
    ReservationRoom,
    HotelCreditLot,
    HotelCreditAllocation,
    CashPaymentAllocation,
    HotelCreditLotEntitlement
  }

  @max_sqlite_integer 9_223_372_036_854_775_807

  @doc """
  Applies partner operations independently and in order. Each operation has its own transaction,
  so a rejection cannot undo an earlier successful operation in the same batch.
  """
  def process_batch(operations) do
    Enum.map(operations, &process_operation/1)
  end

  def get_operation(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil -> nil
      operation -> operation.result
    end
  end

  def get_group(group_id) do
    case Repo.get(Reservation, group_id) do
      nil ->
        nil

      reservation ->
        rooms =
          Repo.all(
            from room in ReservationRoom,
              where: room.group_id == ^group_id,
              order_by: room.position
          )

        group_json(reservation, rooms)
    end
  end

  def get_payment(payment_operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
      nil ->
        :not_found

      %PartnerOperation{
        operation_type: "record_cash_payment",
        result: %{"status" => "applied"} = result
      } = operation ->
        totals =
          Repo.one(
            from allocation in CashPaymentAllocation,
              where: allocation.payment_operation_id == ^payment_operation_id,
              select: %{
                held: sum(allocation.held_cents),
                refunded: sum(allocation.refunded_cents),
                retained: sum(allocation.retained_cents),
                converted: sum(allocation.converted_cents),
                reduced: sum(allocation.reduced_cents),
                charged_back: sum(allocation.charged_back_cents)
              }
          )

        amounts = %{
          held: totals.held || 0,
          refunded: totals.refunded || 0,
          retained: totals.retained || 0,
          converted: totals.converted || 0,
          reduced: totals.reduced || 0,
          charged_back: totals.charged_back || 0
        }

        {:ok,
         %{
           payment_operation_id: operation.operation_id,
           original_group_id: result["group_id"],
           recorded_cents: result["amount_cents"],
           held_cents: amounts.held,
           refunded_cents: amounts.refunded,
           retained_cents: amounts.retained,
           converted_to_credit_cents: amounts.converted,
           reduced_cents: amounts.reduced,
           charged_back_cents: amounts.charged_back
         }}

      %PartnerOperation{} ->
        :not_reconcilable
    end
  end

  def ledger(as_of_date \\ Date.utc_today()) do
    cash =
      Repo.one(
        from allocation in CashPaymentAllocation,
          select: %{
            held: sum(allocation.held_cents),
            refunded: sum(allocation.refunded_cents),
            retained: sum(allocation.retained_cents),
            converted: sum(allocation.converted_cents),
            reduced: sum(allocation.reduced_cents),
            charged_back: sum(allocation.charged_back_cents)
          }
      )

    available_credit =
      Repo.one(
        from lot in HotelCreditLot,
          where:
            lot.issued_on <= ^as_of_date and lot.expires_on >= ^as_of_date and
              lot.remaining_cents > 0,
          select: sum(lot.remaining_cents)
      ) || 0

    applied_credit =
      Repo.one(
        from allocation in HotelCreditAllocation,
          join: reservation in Reservation,
          on: reservation.group_id == allocation.group_id,
          where: reservation.status == "active",
          select: sum(allocation.amount_cents)
      ) || 0

    credit_shortfall =
      Repo.all(
        from lot in HotelCreditLot,
          left_join: allocation in HotelCreditAllocation,
          on: allocation.credit_lot_id == lot.id,
          left_join: reservation in Reservation,
          on: reservation.group_id == allocation.group_id and reservation.status == "active",
          group_by: [lot.id, lot.unrecovered_clawback_cents],
          select:
            {lot.unrecovered_clawback_cents,
             sum(
               fragment(
                 "CASE WHEN ? IS NULL THEN 0 ELSE ? END",
                 reservation.group_id,
                 allocation.amount_cents
               )
             )}
      )
      |> Enum.reduce(0, fn {clawback, applied}, total -> total + min(clawback, applied || 0) end)

    %{
      cash_held_cents: cash.held || 0,
      cash_refunded_cents: cash.refunded || 0,
      cash_retained_cents: cash.retained || 0,
      cash_converted_to_credit_cents: cash.converted || 0,
      cash_reduced_cents: cash.reduced || 0,
      cash_charged_back_cents: cash.charged_back || 0,
      credit_liability_cents: available_credit + applied_credit,
      credit_shortfall_cents: credit_shortfall
    }
  end

  def guest_credit(guest_id, as_of_date \\ Date.utc_today()) do
    lots =
      Repo.all(
        from lot in HotelCreditLot,
          where:
            lot.guest_id == ^guest_id and lot.issued_on <= ^as_of_date and
              lot.expires_on >= ^as_of_date and lot.remaining_cents > 0,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )

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

  defp process_operation(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")

    if valid_identifier?(operation_id) do
      process_durable_operation(operation, operation_id)
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp process_operation(_operation), do: rejected(nil, "invalid_operation")

  defp process_durable_operation(operation, operation_id) do
    submission = operation |> Jason.encode!() |> Jason.decode!()

    case Repo.transaction(
           fn ->
             case Repo.get_by(PartnerOperation, operation_id: operation_id) do
               %PartnerOperation{submission: ^submission, result: result} ->
                 result

               %PartnerOperation{} ->
                 rejected(operation_id, "operation_id_conflict")

               nil ->
                 result = apply_first_operation(operation, operation_id)

                 result_json = result |> Jason.encode!() |> Jason.decode!()

                 Repo.insert!(%PartnerOperation{
                   operation_id: operation_id,
                   operation_type: operation_type(operation),
                   submission: submission,
                   result: result_json
                 })

                 result_json
             end
           end,
           mode: :immediate
         ) do
      {:ok, result} -> result
      {:error, reason} -> raise "operation transaction failed: #{inspect(reason)}"
    end
  end

  defp apply_first_operation(operation, operation_id) do
    try do
      case Map.get(operation, "type") do
        type when is_binary(type) ->
          normalize_rejection(do_process_operation(type, operation, operation_id))

        _ ->
          rejected(operation_id, "invalid_operation")
      end
    catch
      # Handled domain rejections occur before the operation's first write. Catching them here
      # lets the outer transaction commit the original rejection alongside its submission.
      :throw, {:handled_rejection, result} -> result
    end
  end

  defp normalize_rejection({:error, result}), do: result
  defp normalize_rejection(result), do: result

  defp operation_type(operation) do
    case Map.get(operation, "type") do
      type when is_binary(type) -> type
      _ -> nil
    end
  end

  defp do_process_operation("open_group", operation, operation_id) do
    with {:ok, booked_on} <- operation_date(operation, operation_id),
         :ok <-
           require_identifiers(operation, ["group_id", "guest_id", "property_id"], operation_id),
         {:ok, stay} <- open_stay(operation, operation_id),
         {:ok, rate_plan} <- rate_plan(operation, operation_id),
         {:ok, rooms} <- rooms(operation, operation_id),
         {:ok, totals} <- totals(rooms, stay.nights, rate_plan, operation_id) do
      group_id = operation["group_id"]

      if Repo.get(Reservation, group_id) do
        reject!(rejected(operation_id, "group_already_exists", group_id: group_id))
      end

      reservation =
        Repo.insert!(%Reservation{
          group_id: group_id,
          guest_id: operation["guest_id"],
          property_id: operation["property_id"],
          booked_on: booked_on,
          arrival_on: stay.arrival_on,
          departure_on: stay.departure_on,
          rate_plan: rate_plan,
          policy_version: policy_version_for(rate_plan, booked_on),
          status: "active",
          lodging_total_cents: totals.lodging,
          deposit_due_cents: totals.deposit,
          deposit_paid_cents: 0,
          cash_paid_cents: 0,
          credit_paid_cents: 0,
          refunded_cents: 0,
          retained_cents: 0,
          cash_converted_to_credit_cents: 0,
          revision: 1
        })

      Enum.with_index(rooms)
      |> Enum.each(fn {room, position} ->
        lodging = room.nightly_rate_cents * stay.nights
        room_due = room_deposit(lodging, rate_plan)

        Repo.insert!(%ReservationRoom{
          group_id: reservation.group_id,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          position: position,
          deposit_due_cents: room_due,
          status: "active"
        })
      end)

      %{
        operation_id: operation_id,
        status: "applied",
        group_id: group_id,
        deposit_due_cents: totals.deposit,
        revision: 1
      }
    else
      {:error, result} -> result
    end
  end

  defp do_process_operation(type, operation, operation_id)
       when type in [
              "record_cash_payment",
              "apply_hotel_credit",
              "reschedule_group",
              "cancel_group",
              "cancel_rooms"
            ] do
    with :ok <- require_identifiers(operation, ["group_id"], operation_id) do
      group_id = operation["group_id"]

      case Repo.get(Reservation, group_id) do
        nil ->
          reject!(rejected(operation_id, "group_not_found", group_id: group_id))

        reservation ->
          check_revision!(reservation, operation, operation_id)
          check_operation_date!(operation, operation_id, group_id)
          apply_to_reservation(type, operation, reservation, operation_id)
      end
    else
      {:error, result} -> result
    end
  end

  defp do_process_operation(type, operation, operation_id)
       when type in ["reduce_cash_payment", "charge_back_payment"] do
    payment_operation_id = Map.get(operation, "payment_operation_id")

    if not valid_identifier?(payment_operation_id) do
      rejected(operation_id, "invalid_operation")
    else
      case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
        nil ->
          rejected(operation_id, "operation_not_found")

        payment ->
          group_id = get_in(payment.result || %{}, ["group_id"])

          case Repo.get(Reservation, group_id) do
            %Reservation{} = reservation ->
              check_revision!(reservation, operation, operation_id)
              apply_payment_correction(type, operation, reservation, payment, operation_id)

            nil ->
              if applied_cash_payment?(payment) do
                reject!(rejected(operation_id, "group_not_found", group_id: group_id))
              else
                code =
                  if type == "reduce_cash_payment",
                    do: "payment_not_reducible",
                    else: "payment_not_chargeable"

                rejected(operation_id, code)
              end
          end
      end
    end
  end

  defp do_process_operation(_unknown, _operation, operation_id),
    do: rejected(operation_id, "invalid_operation")

  defp apply_to_reservation("record_cash_payment", operation, reservation, operation_id) do
    ensure_active!(reservation, operation_id)

    amount = Map.get(operation, "amount_cents")

    unless is_integer(amount) and amount > 0 do
      reject!(rejected(operation_id, "invalid_amount", group_id: reservation.group_id))
    end

    outstanding = reservation.deposit_due_cents - reservation.deposit_paid_cents

    if amount > outstanding do
      reject!(
        rejected(operation_id, "payment_exceeds_outstanding", group_id: reservation.group_id)
      )
    end

    allocate_cash_to_rooms!(reservation, operation_id, amount)

    updated =
      update_reservation!(reservation, %{
        deposit_paid_cents: reservation.deposit_paid_cents + amount,
        cash_paid_cents: reservation.cash_paid_cents + amount
      })

    %{
      operation_id: operation_id,
      status: "applied",
      group_id: updated.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: updated.deposit_due_cents - updated.deposit_paid_cents,
      revision: updated.revision
    }
  end

  defp apply_to_reservation("apply_hotel_credit", operation, reservation, operation_id) do
    ensure_active!(reservation, operation_id)

    amount = Map.get(operation, "amount_cents")

    unless is_integer(amount) and amount > 0 do
      reject!(rejected(operation_id, "invalid_amount", group_id: reservation.group_id))
    end

    outstanding = reservation.deposit_due_cents - reservation.deposit_paid_cents

    if amount > outstanding do
      reject!(
        rejected(operation_id, "payment_exceeds_outstanding", group_id: reservation.group_id)
      )
    end

    occurred_on = operation_date_value(operation)

    lots =
      Repo.all(
        from lot in HotelCreditLot,
          where:
            lot.guest_id == ^reservation.guest_id and lot.issued_on <= ^occurred_on and
              lot.expires_on >= ^occurred_on and lot.remaining_cents > 0,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )

    available = Enum.reduce(lots, 0, &(&1.remaining_cents + &2))

    if available < amount do
      reject!(rejected(operation_id, "insufficient_credit", group_id: reservation.group_id))
    end

    allocate_credit_to_rooms!(lots, reservation, operation_id, amount)

    updated =
      update_reservation!(reservation, %{
        deposit_paid_cents: reservation.deposit_paid_cents + amount,
        credit_paid_cents: reservation.credit_paid_cents + amount
      })

    %{
      operation_id: operation_id,
      status: "applied",
      group_id: updated.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: updated.deposit_due_cents - updated.deposit_paid_cents,
      revision: updated.revision
    }
  end

  defp apply_to_reservation("reschedule_group", operation, reservation, operation_id) do
    ensure_active!(reservation, operation_id)

    with {:ok, new_arrival} <-
           parse_domain_date(Map.get(operation, "new_arrival_on"), "invalid_stay", operation_id,
             group_id: reservation.group_id
           ),
         true <- Date.compare(new_arrival, operation_date_value(operation)) == :gt do
      shift = Date.diff(new_arrival, reservation.arrival_on)
      new_departure = Date.add(reservation.departure_on, shift)

      updated =
        update_reservation!(reservation, %{arrival_on: new_arrival, departure_on: new_departure})

      %{
        operation_id: operation_id,
        status: "applied",
        group_id: updated.group_id,
        new_arrival_on: new_arrival,
        new_departure_on: new_departure,
        policy_version: policy_version(updated),
        refundable_until: refundable_until(updated),
        revision: updated.revision
      }
    else
      false ->
        reject!(rejected(operation_id, "invalid_stay", group_id: reservation.group_id))

      {:error, result} ->
        reject!(result)
    end
  end

  defp apply_to_reservation("cancel_group", operation, reservation, operation_id) do
    ensure_active!(reservation, operation_id)
    occurred_on = operation_date_value(operation)

    refund_method = Map.get(operation, "refund_method", "cash")

    unless refund_method in ["cash", "hotel_credit"] do
      reject!(rejected(operation_id, "invalid_operation", group_id: reservation.group_id))
    end

    refundable? = refundable?(reservation, occurred_on)

    if refund_method == "hotel_credit" and not refundable? do
      reject!(
        rejected(operation_id, "refund_method_not_available", group_id: reservation.group_id)
      )
    end

    rooms = active_rooms(reservation.group_id)

    settlement =
      settle_rooms!(reservation, rooms, operation_id, occurred_on, refund_method, refundable?)

    updated = settlement.reservation

    %{
      operation_id: operation_id,
      status: "applied",
      group_id: updated.group_id,
      refunded_cents: settlement.refunded_cents,
      retained_cents: settlement.retained_cents,
      credit_issued_cents: settlement.credit_issued_cents,
      revision: updated.revision
    }
  end

  defp apply_to_reservation("cancel_rooms", operation, reservation, operation_id) do
    ensure_active!(reservation, operation_id)

    with {:ok, selected} <-
           selected_rooms(reservation, Map.get(operation, "room_ids"), operation_id),
         {:ok, occurred_on} <- operation_date(operation, operation_id) do
      refund_method = Map.get(operation, "refund_method", "cash")

      unless refund_method in ["cash", "hotel_credit"] do
        reject!(rejected(operation_id, "invalid_operation", group_id: reservation.group_id))
      end

      refundable? = refundable?(reservation, occurred_on)

      if refund_method == "hotel_credit" and not refundable? do
        reject!(
          rejected(operation_id, "refund_method_not_available", group_id: reservation.group_id)
        )
      end

      settlement =
        settle_rooms!(
          reservation,
          selected,
          operation_id,
          occurred_on,
          refund_method,
          refundable?
        )

      %{
        operation_id: operation_id,
        status: "applied",
        group_id: settlement.reservation.group_id,
        cancelled_room_ids: Enum.map(selected, & &1.room_id),
        refunded_cents: settlement.refunded_cents,
        retained_cents: settlement.retained_cents,
        credit_issued_cents: settlement.credit_issued_cents,
        revision: settlement.reservation.revision
      }
    else
      {:error, result} -> result
    end
  end

  defp reject!(result), do: throw({:handled_rejection, result})

  defp check_revision!(reservation, operation, operation_id) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, expected} when is_integer(expected) ->
        if expected == reservation.revision do
          :ok
        else
          reject!(
            rejected(operation_id, "stale_revision",
              group_id: reservation.group_id,
              expected_revision: expected,
              actual_revision: reservation.revision
            )
          )
        end

      {:ok, _invalid} ->
        reject!(rejected(operation_id, "invalid_operation", group_id: reservation.group_id))
    end
  end

  defp update_reservation!(reservation, changes) do
    reservation
    |> Ecto.Changeset.change(Map.put(changes, :revision, reservation.revision + 1))
    |> Repo.update!()
  end

  defp allocate_cash_to_rooms!(reservation, operation_id, amount) do
    rooms = active_rooms(reservation.group_id)

    {allocated, _remaining} =
      Enum.reduce(rooms, {0, amount}, fn room, {allocated, remaining} ->
        capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
        piece = min(max(capacity, 0), remaining)

        if piece > 0 do
          Repo.insert!(%CashPaymentAllocation{
            group_id: reservation.group_id,
            room_id: room.room_id,
            payment_operation_id: operation_id,
            recorded_cents: piece,
            held_cents: piece
          })

          room
          |> Ecto.Changeset.change(cash_paid_cents: room.cash_paid_cents + piece)
          |> Repo.update!()
        end

        {allocated + piece, remaining - piece}
      end)

    if allocated != amount do
      raise "cash allocation did not match validated payment amount"
    end
  end

  defp allocate_credit_to_rooms!(lots, reservation, operation_id, amount) do
    rooms = active_rooms(reservation.group_id)

    {allocated, remaining_lots} =
      Enum.reduce(rooms, {0, lots}, fn room, {allocated, available_lots} ->
        capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
        room_amount = min(max(capacity, 0), amount - allocated)

        {consumed, updated_lots} =
          consume_credit_lots_for_room!(available_lots, room, operation_id, room_amount)

        if consumed > 0 do
          room
          |> Ecto.Changeset.change(credit_paid_cents: room.credit_paid_cents + consumed)
          |> Repo.update!()
        end

        {allocated + consumed, updated_lots}
      end)

    _ = remaining_lots

    if allocated != amount do
      raise "credit allocation did not match validated application amount"
    end
  end

  defp consume_credit_lots_for_room!(lots, room, operation_id, amount) do
    Enum.reduce_while(lots, {0, amount, []}, fn lot, {consumed, remaining, updated_lots} ->
      piece = min(lot.remaining_cents, remaining)

      if piece > 0 do
        lot
        |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - piece)
        |> Repo.update!()

        Repo.insert!(%HotelCreditAllocation{
          credit_lot_id: lot.id,
          group_id: room.group_id,
          room_id: room.room_id,
          funding_operation_id: operation_id,
          amount_cents: piece
        })
      end

      next_lot =
        if piece > 0, do: %{lot | remaining_cents: lot.remaining_cents - piece}, else: lot

      left = remaining - piece
      next = {consumed + piece, left, updated_lots ++ [next_lot]}
      if left == 0, do: {:halt, next}, else: {:cont, next}
    end)
    |> then(fn {consumed, _remaining, updated_lots} ->
      {consumed, updated_lots ++ Enum.drop(lots, length(updated_lots))}
    end)
  end

  defp active_rooms(group_id) do
    Repo.all(
      from room in ReservationRoom,
        where: room.group_id == ^group_id and room.status == "active",
        order_by: room.position
    )
  end

  defp selected_rooms(reservation, room_ids, operation_id)
       when is_list(room_ids) and room_ids != [] do
    if Enum.all?(room_ids, &valid_identifier?/1) and
         length(room_ids) == MapSet.size(MapSet.new(room_ids)) do
      rooms = active_rooms(reservation.group_id)
      selected_ids = MapSet.new(room_ids)
      selected = Enum.filter(rooms, &MapSet.member?(selected_ids, &1.room_id))

      if length(selected) == length(room_ids) do
        {:ok, selected}
      else
        {:error, rejected(operation_id, "invalid_rooms", group_id: reservation.group_id)}
      end
    else
      {:error, rejected(operation_id, "invalid_rooms", group_id: reservation.group_id)}
    end
  end

  defp selected_rooms(reservation, _room_ids, operation_id),
    do: {:error, rejected(operation_id, "invalid_rooms", group_id: reservation.group_id)}

  defp settle_rooms!(reservation, rooms, operation_id, occurred_on, refund_method, refundable?) do
    room_ids = Enum.map(rooms, & &1.room_id)

    cash_allocations =
      Repo.all(
        from allocation in CashPaymentAllocation,
          where:
            allocation.group_id == ^reservation.group_id and allocation.room_id in ^room_ids and
              allocation.held_cents > 0,
          order_by: allocation.id
      )

    cash_held = Enum.reduce(cash_allocations, 0, &(&1.held_cents + &2))
    converted = if refundable? and refund_method == "hotel_credit", do: cash_held, else: 0
    refunded = if refundable? and refund_method == "cash", do: cash_held, else: 0
    retained = if refundable?, do: 0, else: cash_held
    credit_issued = credit_for_cash(converted)

    if credit_issued > @max_sqlite_integer do
      reject!(rejected(operation_id, "invalid_amount", group_id: reservation.group_id))
    end

    Enum.each(cash_allocations, fn allocation ->
      changes =
        cond do
          converted > 0 ->
            [held_cents: 0, converted_cents: allocation.converted_cents + allocation.held_cents]

          refunded > 0 ->
            [held_cents: 0, refunded_cents: allocation.refunded_cents + allocation.held_cents]

          true ->
            [held_cents: 0, retained_cents: allocation.retained_cents + allocation.held_cents]
        end

      allocation |> Ecto.Changeset.change(changes) |> Repo.update!()
    end)

    restore_or_consume_applied_credit!(reservation.group_id, room_ids, occurred_on, refundable?)

    if converted > 0 do
      lot =
        Repo.insert!(%HotelCreditLot{
          guest_id: reservation.guest_id,
          source_operation_id: operation_id,
          remaining_cents: credit_issued,
          issued_on: occurred_on,
          expires_on: Date.add(occurred_on, 365)
        })

      record_lot_entitlements!(lot, cash_allocations)
    end

    Enum.each(rooms, fn room ->
      room
      |> Ecto.Changeset.change(
        status: "cancelled",
        deposit_due_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0
      )
      |> Repo.update!()
    end)

    remaining_rooms = active_rooms(reservation.group_id)
    lodging_total = Enum.reduce(remaining_rooms, 0, &(room_lodging(&1, reservation) + &2))
    due_total = Enum.reduce(remaining_rooms, 0, &(&1.deposit_due_cents + &2))
    cash_total = Enum.reduce(remaining_rooms, 0, &(&1.cash_paid_cents + &2))
    credit_total = Enum.reduce(remaining_rooms, 0, &(&1.credit_paid_cents + &2))

    updated =
      update_reservation!(reservation, %{
        status: if(remaining_rooms == [], do: "cancelled", else: "active"),
        lodging_total_cents: lodging_total,
        deposit_due_cents: due_total,
        deposit_paid_cents: cash_total + credit_total,
        cash_paid_cents: cash_total,
        credit_paid_cents: credit_total,
        refunded_cents: reservation.refunded_cents + refunded,
        retained_cents: reservation.retained_cents + retained,
        cash_converted_to_credit_cents: reservation.cash_converted_to_credit_cents + converted
      })

    %{
      reservation: updated,
      refunded_cents: refunded,
      retained_cents: retained,
      credit_issued_cents: credit_issued
    }
  end

  defp record_lot_entitlements!(lot, cash_allocations) do
    by_source =
      cash_allocations
      |> Enum.group_by(& &1.payment_operation_id, & &1.held_cents)
      |> Enum.map(fn {operation_id, amounts} -> {operation_id, Enum.sum(amounts)} end)
      |> Enum.filter(fn {_operation_id, amount} -> amount > 0 end)
      |> Enum.sort_by(fn
        {nil, _amount} ->
          {0, 0}

        {operation_id, _amount} ->
          id =
            Repo.one(
              from operation in PartnerOperation,
                where: operation.operation_id == ^operation_id,
                select: operation.id
            )

          {1, id || 0}
      end)

    {_running_cash, _running_credit} =
      Enum.reduce(by_source, {0, 0}, fn {operation_id, amount}, {running_cash, running_credit} ->
        next_cash = running_cash + amount
        next_credit = credit_for_cash(next_cash)
        entitlement = next_credit - running_credit

        Repo.insert!(%HotelCreditLotEntitlement{
          credit_lot_id: lot.id,
          payment_operation_id: operation_id,
          cash_cents: amount,
          entitlement_cents: entitlement
        })

        {next_cash, next_credit}
      end)
  end

  defp restore_or_consume_applied_credit!(group_id, room_ids, occurred_on, refundable?) do
    allocations =
      Repo.all(
        from allocation in HotelCreditAllocation,
          where: allocation.group_id == ^group_id and allocation.room_id in ^room_ids,
          preload: [:credit_lot]
      )

    if refundable? do
      allocations
      |> Enum.group_by(& &1.credit_lot_id)
      |> Enum.each(fn {_lot_id, lot_allocations} ->
        lot = hd(lot_allocations).credit_lot

        restore_credit_lot!(
          lot,
          Enum.reduce(lot_allocations, 0, &(&1.amount_cents + &2)),
          occurred_on
        )
      end)
    end

    Enum.each(allocations, &Repo.delete!/1)
  end

  defp restore_credit_lot!(lot, amount, occurred_on) do
    absorbed = min(amount, lot.unrecovered_clawback_cents)
    remaining_clawback = lot.unrecovered_clawback_cents - absorbed
    excess = amount - absorbed

    available =
      if Date.compare(lot.expires_on, occurred_on) != :lt,
        do: lot.remaining_cents + excess,
        else: lot.remaining_cents

    lot
    |> Ecto.Changeset.change(
      remaining_cents: available,
      unrecovered_clawback_cents: remaining_clawback
    )
    |> Repo.update!()
  end

  defp apply_payment_correction(
         "reduce_cash_payment",
         operation,
         reservation,
         payment,
         operation_id
       ) do
    unless applied_cash_payment?(payment) do
      reject!(rejected(operation_id, "payment_not_reducible", group_id: reservation.group_id))
    end

    payment_id = payment.operation_id
    allocations = payment_allocations(payment_id)
    held = Enum.reduce(allocations, 0, &(&1.held_cents + &2))

    if held == 0 do
      reject!(rejected(operation_id, "payment_not_reducible", group_id: reservation.group_id))
    end

    amount = Map.get(operation, "amount_cents")

    unless is_integer(amount) and amount > 0 do
      reject!(rejected(operation_id, "invalid_amount", group_id: reservation.group_id))
    end

    if amount > held do
      reject!(
        rejected(operation_id, "reduction_exceeds_held_cash", group_id: reservation.group_id)
      )
    end

    reduce_allocations!(allocations, amount)
    adjust_room_cash!(allocations, amount, :reduce)

    updated =
      update_reservation!(reservation, %{
        cash_paid_cents: reservation.cash_paid_cents - amount,
        deposit_paid_cents: reservation.deposit_paid_cents - amount
      })

    %{
      operation_id: operation_id,
      status: "applied",
      payment_operation_id: payment_id,
      group_id: reservation.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: outstanding(updated),
      revision: updated.revision
    }
  end

  defp apply_payment_correction(
         "charge_back_payment",
         _operation,
         reservation,
         payment,
         operation_id
       ) do
    unless applied_cash_payment?(payment) do
      reject!(rejected(operation_id, "payment_not_chargeable", group_id: reservation.group_id))
    end

    payment_id = payment.operation_id
    allocations = payment_allocations(payment_id)
    recorded = Enum.reduce(allocations, 0, &(&1.recorded_cents + &2))
    reduced = Enum.reduce(allocations, 0, &(&1.reduced_cents + &2))
    already_charged_back = Enum.reduce(allocations, 0, &(&1.charged_back_cents + &2))

    if recorded == reduced or already_charged_back > 0 do
      reject!(rejected(operation_id, "payment_not_chargeable", group_id: reservation.group_id))
    end

    held = Enum.reduce(allocations, 0, &(&1.held_cents + &2))
    refunded = Enum.reduce(allocations, 0, &(&1.refunded_cents + &2))
    retained = Enum.reduce(allocations, 0, &(&1.retained_cents + &2))
    converted = Enum.reduce(allocations, 0, &(&1.converted_cents + &2))
    charged_back = recorded - reduced

    Enum.each(allocations, fn allocation ->
      movable =
        allocation.held_cents + allocation.refunded_cents + allocation.retained_cents +
          allocation.converted_cents

      allocation
      |> Ecto.Changeset.change(
        held_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        converted_cents: 0,
        charged_back_cents: allocation.charged_back_cents + movable
      )
      |> Repo.update!()
    end)

    adjust_room_cash!(allocations, held, :chargeback)
    revoke_credit_entitlements!(payment_id)

    updated =
      update_reservation!(reservation, %{
        cash_paid_cents: reservation.cash_paid_cents - held,
        deposit_paid_cents: reservation.deposit_paid_cents - held,
        refunded_cents: max(reservation.refunded_cents - refunded, 0),
        retained_cents: max(reservation.retained_cents - retained, 0),
        cash_converted_to_credit_cents:
          max(reservation.cash_converted_to_credit_cents - converted, 0)
      })

    %{
      operation_id: operation_id,
      status: "applied",
      payment_operation_id: payment_id,
      group_id: reservation.group_id,
      charged_back_cents: charged_back,
      outstanding_deposit_cents: outstanding(updated),
      revision: updated.revision
    }
  end

  defp applied_cash_payment?(%PartnerOperation{
         operation_type: "record_cash_payment",
         result: %{"status" => "applied", "amount_cents" => amount, "group_id" => group_id}
       })
       when is_integer(amount) and amount > 0 and is_binary(group_id),
       do: true

  defp applied_cash_payment?(_), do: false

  defp payment_allocations(payment_id) do
    Repo.all(
      from allocation in CashPaymentAllocation,
        where: allocation.payment_operation_id == ^payment_id,
        order_by: [desc: allocation.id]
    )
  end

  defp reduce_allocations!(allocations, amount) do
    {_left, _} =
      Enum.reduce_while(allocations, {amount, 0}, fn allocation, {remaining, _unused} ->
        reduced = min(allocation.held_cents, remaining)

        if reduced > 0 do
          allocation
          |> Ecto.Changeset.change(
            held_cents: allocation.held_cents - reduced,
            reduced_cents: allocation.reduced_cents + reduced
          )
          |> Repo.update!()
        end

        left = remaining - reduced
        if left == 0, do: {:halt, {0, reduced}}, else: {:cont, {left, reduced}}
      end)
  end

  defp adjust_room_cash!(allocations, amount, _reason) do
    # Allocation structs were loaded before reductions/chargebacks, so use the requested
    # amount across reverse fill order and update each affected room by its removed portion.
    {_left, changes} =
      Enum.reduce(allocations, {amount, []}, fn allocation, {remaining, changes} ->
        removed = min(allocation.held_cents, remaining)
        {remaining - removed, changes ++ [{{allocation.group_id, allocation.room_id}, removed}]}
      end)

    Enum.each(Enum.group_by(changes, &elem(&1, 0)), fn {{group_id, room_id}, entries} ->
      removed = Enum.reduce(entries, 0, fn {_key, piece}, total -> total + piece end)

      if removed > 0 do
        room = Repo.get_by!(ReservationRoom, group_id: group_id, room_id: room_id)

        room
        |> Ecto.Changeset.change(cash_paid_cents: room.cash_paid_cents - removed)
        |> Repo.update!()
      end
    end)

    :ok
  end

  defp revoke_credit_entitlements!(payment_id) do
    entitlements =
      Repo.all(
        from entitlement in HotelCreditLotEntitlement,
          where: entitlement.payment_operation_id == ^payment_id,
          preload: [:credit_lot]
      )

    Enum.each(entitlements, fn entitlement ->
      lot = entitlement.credit_lot
      removed = min(lot.remaining_cents, entitlement.entitlement_cents)
      unrecovered = entitlement.entitlement_cents - removed

      lot
      |> Ecto.Changeset.change(
        remaining_cents: lot.remaining_cents - removed,
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents + unrecovered
      )
      |> Repo.update!()
    end)
  end

  defp outstanding(%Reservation{status: "active"} = reservation),
    do: max(reservation.deposit_due_cents - reservation.deposit_paid_cents, 0)

  defp outstanding(_reservation), do: 0

  defp room_lodging(room, reservation),
    do: room.nightly_rate_cents * Date.diff(reservation.departure_on, reservation.arrival_on)

  defp room_deposit(lodging, "flexible"), do: div(lodging * 20 + 50, 100)
  defp room_deposit(lodging, "advance_purchase"), do: lodging

  defp ensure_active!(%Reservation{status: "active"}, _operation_id), do: :ok

  defp ensure_active!(reservation, operation_id) do
    reject!(rejected(operation_id, "group_not_active", group_id: reservation.group_id))
  end

  defp refundable?(%Reservation{rate_plan: "flexible"} = reservation, occurred_on) do
    Date.diff(reservation.arrival_on, occurred_on) >= cancellation_window(reservation)
  end

  defp refundable?(_reservation, _occurred_on), do: false

  defp policy_version(%Reservation{policy_version: version}) when is_binary(version), do: version

  defp policy_version(%Reservation{rate_plan: rate_plan, booked_on: booked_on}) do
    policy_version_for(rate_plan, booked_on)
  end

  defp policy_version_for("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version_for("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp cancellation_window(%Reservation{rate_plan: "advance_purchase"}), do: 0

  defp cancellation_window(reservation),
    do: if(policy_version(reservation) == "flex-30", do: 30, else: 14)

  defp refundable_until(%Reservation{rate_plan: "advance_purchase"}), do: nil

  defp refundable_until(reservation) do
    Date.add(reservation.arrival_on, -cancellation_window(reservation))
  end

  defp credit_for_cash(0), do: 0

  defp credit_for_cash(cash_cents) do
    bonus = div(cash_cents * 10 + 50, 100)
    cash_cents + bonus
  end

  defp operation_date(operation, operation_id) do
    case parse_date(Map.get(operation, "occurred_on")) do
      {:ok, date} -> {:ok, date}
      :error -> {:error, rejected(operation_id, "invalid_operation")}
    end
  end

  defp operation_date_value(operation), do: elem(parse_date(operation["occurred_on"]), 1)

  defp check_operation_date!(operation, operation_id, group_id) do
    case parse_date(Map.get(operation, "occurred_on")) do
      {:ok, _date} -> :ok
      :error -> reject!(rejected(operation_id, "invalid_operation", group_id: group_id))
    end
  end

  defp open_stay(operation, operation_id) do
    with {:ok, arrival} <-
           parse_domain_date(Map.get(operation, "arrival_on"), "invalid_stay", operation_id),
         {:ok, departure} <-
           parse_domain_date(Map.get(operation, "departure_on"), "invalid_stay", operation_id),
         true <- Date.compare(departure, arrival) == :gt do
      {:ok,
       %{arrival_on: arrival, departure_on: departure, nights: Date.diff(departure, arrival)}}
    else
      false -> {:error, rejected(operation_id, "invalid_stay")}
      {:error, result} -> {:error, result}
    end
  end

  defp rate_plan(operation, operation_id) do
    case Map.get(operation, "rate_plan") do
      plan when plan in ["flexible", "advance_purchase"] -> {:ok, plan}
      _ -> {:error, rejected(operation_id, "invalid_rate_plan")}
    end
  end

  defp rooms(operation, operation_id) do
    case Map.get(operation, "rooms") do
      room_list when is_list(room_list) and room_list != [] ->
        parsed = Enum.map(room_list, &parse_room/1)

        if Enum.all?(parsed, &match?({:ok, _}, &1)) do
          room_values = Enum.map(parsed, fn {:ok, room} -> room end)
          room_ids = Enum.map(room_values, & &1.room_id)

          if length(room_ids) == MapSet.size(MapSet.new(room_ids)) do
            {:ok, room_values}
          else
            {:error, rejected(operation_id, "invalid_rooms")}
          end
        else
          {:error, rejected(operation_id, "invalid_rooms")}
        end

      _ ->
        {:error, rejected(operation_id, "invalid_rooms")}
    end
  end

  defp parse_room(room) when is_map(room) do
    room_id = Map.get(room, "room_id")
    rate = Map.get(room, "nightly_rate_cents")

    if valid_identifier?(room_id) and is_integer(rate) and rate > 0 and
         rate <= @max_sqlite_integer do
      {:ok, %{room_id: room_id, nightly_rate_cents: rate}}
    else
      :error
    end
  end

  defp parse_room(_), do: :error

  defp totals(rooms, nights, rate_plan, operation_id) do
    Enum.reduce_while(rooms, {:ok, %{lodging: 0, deposit: 0}}, fn room, {:ok, acc} ->
      lodging = room.nightly_rate_cents * nights

      deposit =
        case rate_plan do
          "flexible" -> div(lodging * 20 + 50, 100)
          "advance_purchase" -> lodging
        end

      next = %{lodging: acc.lodging + lodging, deposit: acc.deposit + deposit}

      if lodging <= @max_sqlite_integer and deposit <= @max_sqlite_integer and
           next.lodging <= @max_sqlite_integer and next.deposit <= @max_sqlite_integer do
        {:cont, {:ok, next}}
      else
        {:halt, {:error, rejected(operation_id, "invalid_rooms")}}
      end
    end)
  end

  defp require_identifiers(operation, keys, operation_id) do
    if Enum.all?(keys, &valid_identifier?(Map.get(operation, &1))) do
      :ok
    else
      {:error, rejected(operation_id, "invalid_operation")}
    end
  end

  defp parse_domain_date(value, code, operation_id, extra \\ []) do
    case parse_date(value) do
      {:ok, date} -> {:ok, date}
      :error -> {:error, rejected(operation_id, code, extra)}
    end
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp parse_date(_), do: :error

  defp valid_identifier?(value), do: is_binary(value) and String.trim(value) != ""

  defp rejected(operation_id, code, extra \\ []) do
    Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, Map.new(extra))
  end

  defp group_json(reservation, rooms) do
    active_rooms = Enum.filter(rooms, &(&1.status == "active"))
    lodging_total = Enum.reduce(active_rooms, 0, &(room_lodging(&1, reservation) + &2))
    deposit_due = Enum.reduce(active_rooms, 0, &(&1.deposit_due_cents + &2))
    cash_paid = Enum.reduce(active_rooms, 0, &(&1.cash_paid_cents + &2))
    credit_paid = Enum.reduce(active_rooms, 0, &(&1.credit_paid_cents + &2))
    deposit_paid = cash_paid + credit_paid

    %{
      group_id: reservation.group_id,
      guest_id: reservation.guest_id,
      property_id: reservation.property_id,
      revision: reservation.revision,
      booked_on: Date.to_iso8601(reservation.booked_on),
      arrival_on: Date.to_iso8601(reservation.arrival_on),
      departure_on: Date.to_iso8601(reservation.departure_on),
      rate_plan: reservation.rate_plan,
      policy_version: policy_version(reservation),
      refundable_until: refundable_until(reservation),
      status: reservation.status,
      rooms:
        Enum.map(rooms, fn room ->
          %{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            lodging_total_cents: room_lodging(room, reservation),
            status: room.status,
            deposit_due_cents: room.deposit_due_cents,
            cash_paid_cents: room.cash_paid_cents,
            credit_paid_cents: room.credit_paid_cents
          }
        end),
      lodging_total_cents: lodging_total,
      deposit_due_cents: deposit_due,
      deposit_paid_cents: deposit_paid,
      cash_paid_cents: cash_paid,
      credit_paid_cents: credit_paid,
      outstanding_deposit_cents: max(deposit_due - deposit_paid, 0)
    }
  end
end
