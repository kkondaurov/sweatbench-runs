defmodule GroupStay.Reservations do
  import Ecto.Query

  alias GroupStay.{Repo, Reservation, ReservationRoom}

  @max_sqlite_integer 9_223_372_036_854_775_807

  @doc """
  Applies partner operations independently and in order. Each operation has its own transaction,
  so a rejection cannot undo an earlier successful operation in the same batch.
  """
  def process_batch(operations) do
    Enum.map(operations, &process_operation/1)
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

  def ledger do
    held =
      Repo.one(
        from reservation in Reservation,
          where: reservation.status == "active",
          select: sum(reservation.deposit_paid_cents)
      ) || 0

    refunded =
      Repo.one(from reservation in Reservation, select: sum(reservation.refunded_cents)) || 0

    retained =
      Repo.one(from reservation in Reservation, select: sum(reservation.retained_cents)) || 0

    %{
      cash_held_cents: held,
      cash_refunded_cents: refunded,
      cash_retained_cents: retained
    }
  end

  defp process_operation(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")
    type = Map.get(operation, "type")

    if valid_identifier?(operation_id) and is_binary(type) do
      do_process_operation(type, operation, operation_id)
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp process_operation(_operation), do: rejected(nil, "invalid_operation")

  defp do_process_operation("open_group", operation, operation_id) do
    with {:ok, booked_on} <- operation_date(operation, operation_id),
         :ok <-
           require_identifiers(operation, ["group_id", "guest_id", "property_id"], operation_id),
         {:ok, stay} <- open_stay(operation, operation_id),
         {:ok, rate_plan} <- rate_plan(operation, operation_id),
         {:ok, rooms} <- rooms(operation, operation_id),
         {:ok, totals} <- totals(rooms, stay.nights, rate_plan, operation_id) do
      group_id = operation["group_id"]

      transact(fn ->
        if Repo.get(Reservation, group_id) do
          Repo.rollback(rejected(operation_id, "group_already_exists", group_id: group_id))
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
            status: "active",
            lodging_total_cents: totals.lodging,
            deposit_due_cents: totals.deposit,
            deposit_paid_cents: 0,
            refunded_cents: 0,
            retained_cents: 0,
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
      end)
    else
      {:error, result} -> result
    end
  end

  defp do_process_operation(type, operation, operation_id)
       when type in ["record_cash_payment", "reschedule_group", "cancel_group"] do
    with :ok <- require_identifiers(operation, ["group_id"], operation_id) do
      group_id = operation["group_id"]

      transact(fn ->
        case Repo.get(Reservation, group_id) do
          nil ->
            Repo.rollback(rejected(operation_id, "group_not_found", group_id: group_id))

          reservation ->
            check_revision!(reservation, operation, operation_id)
            check_operation_date!(operation, operation_id, group_id)
            apply_to_reservation(type, operation, reservation, operation_id)
        end
      end)
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
      Repo.rollback(rejected(operation_id, "invalid_amount", group_id: reservation.group_id))
    end

    outstanding = reservation.deposit_due_cents - reservation.deposit_paid_cents

    if amount > outstanding do
      Repo.rollback(
        rejected(operation_id, "payment_exceeds_outstanding", group_id: reservation.group_id)
      )
    end

    updated =
      update_reservation!(reservation, %{
        deposit_paid_cents: reservation.deposit_paid_cents + amount
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
        revision: updated.revision
      }
    else
      false ->
        Repo.rollback(rejected(operation_id, "invalid_stay", group_id: reservation.group_id))

      {:error, result} ->
        Repo.rollback(result)
    end
  end

  defp apply_to_reservation("cancel_group", operation, reservation, operation_id) do
    ensure_active!(reservation, operation_id)
    occurred_on = operation_date_value(operation)

    refundable? =
      reservation.rate_plan == "flexible" and Date.diff(reservation.arrival_on, occurred_on) >= 14

    refunded = if refundable?, do: reservation.deposit_paid_cents, else: 0
    retained = if refundable?, do: 0, else: reservation.deposit_paid_cents

    updated =
      update_reservation!(reservation, %{
        status: "cancelled",
        refunded_cents: refunded,
        retained_cents: retained
      })

    %{
      operation_id: operation_id,
      status: "applied",
      group_id: updated.group_id,
      refunded_cents: refunded,
      retained_cents: retained,
      revision: updated.revision
    }
  end

  defp transact(fun) do
    case Repo.transaction(fun, mode: :immediate) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp check_revision!(reservation, operation, operation_id) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, expected} when is_integer(expected) ->
        if expected == reservation.revision do
          :ok
        else
          Repo.rollback(
            rejected(operation_id, "stale_revision",
              group_id: reservation.group_id,
              expected_revision: expected,
              actual_revision: reservation.revision
            )
          )
        end

      {:ok, _invalid} ->
        Repo.rollback(rejected(operation_id, "invalid_operation", group_id: reservation.group_id))
    end
  end

  defp update_reservation!(reservation, changes) do
    reservation
    |> Ecto.Changeset.change(Map.put(changes, :revision, reservation.revision + 1))
    |> Repo.update!()
  end

  defp ensure_active!(%Reservation{status: "active"}, _operation_id), do: :ok

  defp ensure_active!(reservation, operation_id) do
    Repo.rollback(rejected(operation_id, "group_not_active", group_id: reservation.group_id))
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
      :error -> Repo.rollback(rejected(operation_id, "invalid_operation", group_id: group_id))
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
      status: reservation.status,
      rooms:
        Enum.map(rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: reservation.lodging_total_cents,
      deposit_due_cents: reservation.deposit_due_cents,
      deposit_paid_cents: reservation.deposit_paid_cents,
      outstanding_deposit_cents:
        if(reservation.status == "active",
          do: reservation.deposit_due_cents - reservation.deposit_paid_cents,
          else: 0
        )
    }
  end
end
