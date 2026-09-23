defmodule GroupStay.Reservations do
  import Ecto.Query

  alias GroupStay.{
    Repo,
    Reservation,
    PartnerOperation,
    ReservationRoom,
    HotelCreditLot,
    HotelCreditAllocation
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

  def ledger(as_of_date \\ Date.utc_today()) do
    held =
      Repo.one(
        from reservation in Reservation,
          where: reservation.status == "active",
          select: sum(reservation.cash_paid_cents)
      ) || 0

    refunded =
      Repo.one(from reservation in Reservation, select: sum(reservation.refunded_cents)) || 0

    retained =
      Repo.one(from reservation in Reservation, select: sum(reservation.retained_cents)) || 0

    converted =
      Repo.one(
        from reservation in Reservation,
          select: sum(reservation.cash_converted_to_credit_cents)
      ) || 0

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

    %{
      cash_held_cents: held,
      cash_refunded_cents: refunded,
      cash_retained_cents: retained,
      cash_converted_to_credit_cents: converted,
      credit_liability_cents: available_credit + applied_credit
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
        Repo.insert!(%ReservationRoom{
          group_id: reservation.group_id,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          position: position
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
              "cancel_group"
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

    consume_credit_lots!(lots, reservation.group_id, amount)

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

    cash_refunded =
      if refundable? and refund_method == "cash", do: reservation.cash_paid_cents, else: 0

    cash_retained = if refundable?, do: 0, else: reservation.cash_paid_cents

    converted =
      if refundable? and refund_method == "hotel_credit", do: reservation.cash_paid_cents, else: 0

    credit_issued = credit_for_cash(converted)

    if credit_issued > @max_sqlite_integer do
      reject!(rejected(operation_id, "invalid_amount", group_id: reservation.group_id))
    end

    settle_applied_credit!(reservation, occurred_on, refundable?)

    if credit_issued > 0 do
      Repo.insert!(%HotelCreditLot{
        guest_id: reservation.guest_id,
        source_operation_id: operation_id,
        remaining_cents: credit_issued,
        issued_on: occurred_on,
        expires_on: Date.add(occurred_on, 365)
      })
    end

    updated =
      update_reservation!(reservation, %{
        status: "cancelled",
        refunded_cents: cash_refunded,
        retained_cents: cash_retained,
        cash_converted_to_credit_cents: reservation.cash_converted_to_credit_cents + converted
      })

    %{
      operation_id: operation_id,
      status: "applied",
      group_id: updated.group_id,
      refunded_cents: cash_refunded,
      retained_cents: cash_retained,
      credit_issued_cents: credit_issued,
      revision: updated.revision
    }
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

  defp ensure_active!(%Reservation{status: "active"}, _operation_id), do: :ok

  defp ensure_active!(reservation, operation_id) do
    reject!(rejected(operation_id, "group_not_active", group_id: reservation.group_id))
  end

  defp consume_credit_lots!(lots, group_id, amount) do
    Enum.reduce_while(lots, amount, fn lot, remaining ->
      consumed = min(lot.remaining_cents, remaining)

      if consumed > 0 do
        lot
        |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - consumed)
        |> Repo.update!()

        Repo.insert!(%HotelCreditAllocation{
          credit_lot_id: lot.id,
          group_id: group_id,
          amount_cents: consumed
        })
      end

      left = remaining - consumed
      if left == 0, do: {:halt, 0}, else: {:cont, left}
    end)

    :ok
  end

  defp settle_applied_credit!(reservation, occurred_on, refundable?) do
    allocations =
      Repo.all(
        from allocation in HotelCreditAllocation,
          where: allocation.group_id == ^reservation.group_id,
          preload: [:credit_lot]
      )

    Enum.each(allocations, fn allocation ->
      if refundable? and Date.compare(allocation.credit_lot.expires_on, occurred_on) != :lt do
        allocation.credit_lot
        |> Ecto.Changeset.change(
          remaining_cents: allocation.credit_lot.remaining_cents + allocation.amount_cents
        )
        |> Repo.update!()
      end

      Repo.delete!(allocation)
    end)
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
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: reservation.lodging_total_cents,
      deposit_due_cents: reservation.deposit_due_cents,
      deposit_paid_cents: reservation.deposit_paid_cents,
      cash_paid_cents: reservation.cash_paid_cents,
      credit_paid_cents: reservation.credit_paid_cents,
      outstanding_deposit_cents:
        if(reservation.status == "active",
          do: reservation.deposit_due_cents - reservation.deposit_paid_cents,
          else: 0
        )
    }
  end
end
