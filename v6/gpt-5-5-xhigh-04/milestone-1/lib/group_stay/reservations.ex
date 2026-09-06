defmodule GroupStay.Reservations do
  @moduledoc """
  Domain operations for partner-managed group reservations.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.{Group, Room}

  @active "active"
  @cancelled "cancelled"
  @flexible "flexible"
  @advance_purchase "advance_purchase"

  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        {:error, :group_not_found}

      group ->
        {:ok,
         group |> Repo.preload(rooms: from(r in Room, order_by: r.position)) |> present_group()}
    end
  end

  def get_group(_group_id), do: {:error, :group_not_found}

  def ledger_totals do
    %{
      cash_held_cents: sum_groups(:deposit_paid_cents, status: @active),
      cash_refunded_cents: sum_groups(:cash_refunded_cents),
      cash_retained_cents: sum_groups(:cash_retained_cents)
    }
  end

  defp process_operation(operation) do
    case Repo.transaction(fn ->
           case apply_operation(operation) do
             {:ok, result} -> result
             {:reject, result} -> Repo.rollback(result)
           end
         end) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp apply_operation(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp apply_operation(%{"type" => "record_cash_payment"} = operation) do
    with_existing_group(operation, fn group -> record_cash_payment(operation, group) end)
  end

  defp apply_operation(%{"type" => "reschedule_group"} = operation) do
    with_existing_group(operation, fn group -> reschedule_group(operation, group) end)
  end

  defp apply_operation(%{"type" => "cancel_group"} = operation) do
    with_existing_group(operation, fn group -> cancel_group(operation, group) end)
  end

  defp apply_operation(operation) when is_map(operation) do
    {:reject, rejected(operation, "invalid_operation")}
  end

  defp apply_operation(_operation) do
    {:reject, rejected(%{}, "invalid_operation")}
  end

  defp open_group(operation) do
    with :ok <- require_common_fields(operation),
         {:ok, group_id} <- fetch_string(operation, "group_id"),
         :ok <- ensure_group_available(operation, group_id),
         {:ok, guest_id} <- fetch_string(operation, "guest_id"),
         {:ok, property_id} <- fetch_string(operation, "property_id"),
         {:ok, booked_on} <- fetch_date(operation, "occurred_on", "invalid_operation"),
         {:ok, arrival_on} <- fetch_date(operation, "arrival_on", "invalid_stay"),
         {:ok, departure_on} <- fetch_date(operation, "departure_on", "invalid_stay"),
         :ok <- validate_stay(operation, arrival_on, departure_on),
         {:ok, rooms} <- validate_rooms(operation),
         {:ok, rate_plan} <- validate_rate_plan(operation),
         totals <- calculate_totals(rooms, arrival_on, departure_on, rate_plan),
         {:ok, group} <-
           insert_group(%{
             group_id: group_id,
             guest_id: guest_id,
             property_id: property_id,
             booked_on: booked_on,
             arrival_on: arrival_on,
             departure_on: departure_on,
             rate_plan: rate_plan,
             lodging_total_cents: totals.lodging_total_cents,
             deposit_due_cents: totals.deposit_due_cents
           }),
         :ok <- insert_rooms(group, rooms) do
      {:ok,
       %{
         operation_id: operation_id(operation),
         status: "applied",
         group_id: group.group_id,
         deposit_due_cents: group.deposit_due_cents,
         revision: group.revision
       }}
    else
      {:reject, result} -> {:reject, result}
    end
  end

  defp record_cash_payment(operation, group) do
    with :ok <- ensure_active(operation, group),
         {:ok, amount_cents} <-
           fetch_positive_integer(operation, "amount_cents", "invalid_amount"),
         outstanding <- outstanding_deposit_cents(group),
         :ok <- ensure_payment_fits(operation, group, amount_cents, outstanding) do
      updated =
        group
        |> change(
          deposit_paid_cents: group.deposit_paid_cents + amount_cents,
          revision: group.revision + 1
        )
        |> Repo.update!()

      {:ok,
       %{
         operation_id: operation_id(operation),
         status: "applied",
         group_id: updated.group_id,
         amount_cents: amount_cents,
         outstanding_deposit_cents: outstanding_deposit_cents(updated),
         revision: updated.revision
       }}
    else
      {:reject, result} -> {:reject, result}
    end
  end

  defp reschedule_group(operation, group) do
    with :ok <- ensure_active(operation, group),
         {:ok, occurred_on} <- fetch_date(operation, "occurred_on", "invalid_operation"),
         {:ok, new_arrival_on} <- fetch_date(operation, "new_arrival_on", "invalid_stay"),
         :ok <- ensure_future_arrival(operation, group, new_arrival_on, occurred_on) do
      shift_days = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift_days)

      updated =
        group
        |> change(
          arrival_on: new_arrival_on,
          departure_on: new_departure_on,
          revision: group.revision + 1
        )
        |> Repo.update!()

      {:ok,
       %{
         operation_id: operation_id(operation),
         status: "applied",
         group_id: updated.group_id,
         new_arrival_on: Date.to_iso8601(updated.arrival_on),
         new_departure_on: Date.to_iso8601(updated.departure_on),
         revision: updated.revision
       }}
    else
      {:reject, result} -> {:reject, result}
    end
  end

  defp cancel_group(operation, group) do
    with :ok <- ensure_active(operation, group),
         {:ok, occurred_on} <- fetch_date(operation, "occurred_on", "invalid_operation") do
      {refunded_cents, retained_cents} = cancellation_settlement(group, occurred_on)

      updated =
        group
        |> change(
          status: @cancelled,
          cash_refunded_cents: group.cash_refunded_cents + refunded_cents,
          cash_retained_cents: group.cash_retained_cents + retained_cents,
          revision: group.revision + 1
        )
        |> Repo.update!()

      {:ok,
       %{
         operation_id: operation_id(operation),
         status: "applied",
         group_id: updated.group_id,
         refunded_cents: refunded_cents,
         retained_cents: retained_cents,
         revision: updated.revision
       }}
    else
      {:reject, result} -> {:reject, result}
    end
  end

  defp with_existing_group(operation, callback) do
    with :ok <- require_common_fields(operation),
         {:ok, group_id} <- fetch_string(operation, "group_id") do
      case Repo.get_by(Group, group_id: group_id) do
        nil ->
          {:reject, rejected(operation, "group_not_found")}

        group ->
          case ensure_fresh_revision(operation, group) do
            :ok -> callback.(group)
            {:reject, result} -> {:reject, result}
          end
      end
    else
      {:reject, result} -> {:reject, result}
    end
  end

  defp require_common_fields(operation) do
    with {:ok, _operation_id} <- fetch_string(operation, "operation_id"),
         {:ok, _occurred_on} <- fetch_date(operation, "occurred_on", "invalid_operation") do
      :ok
    else
      {:reject, _result} -> {:reject, rejected(operation, "invalid_operation")}
    end
  end

  defp ensure_group_available(operation, group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> :ok
      _group -> {:reject, rejected(operation, "group_already_exists")}
    end
  end

  defp ensure_fresh_revision(operation, group) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, expected_revision} when expected_revision == group.revision ->
        :ok

      {:ok, expected_revision} ->
        {:reject,
         %{
           operation_id: operation_id(operation),
           status: "rejected",
           code: "stale_revision",
           group_id: group.group_id,
           expected_revision: expected_revision,
           actual_revision: group.revision
         }}
    end
  end

  defp ensure_active(_operation, %Group{status: @active}), do: :ok

  defp ensure_active(operation, _group) do
    {:reject, rejected(operation, "group_not_active")}
  end

  defp ensure_payment_fits(_operation, _group, amount_cents, outstanding)
       when amount_cents <= outstanding do
    :ok
  end

  defp ensure_payment_fits(operation, _group, _amount_cents, _outstanding) do
    {:reject, rejected(operation, "payment_exceeds_outstanding")}
  end

  defp ensure_future_arrival(operation, _group, new_arrival_on, occurred_on) do
    cond do
      Date.compare(new_arrival_on, occurred_on) == :gt ->
        :ok

      true ->
        {:reject, rejected(operation, "invalid_stay")}
    end
  end

  defp validate_stay(operation, arrival_on, departure_on) do
    if Date.diff(departure_on, arrival_on) >= 1 do
      :ok
    else
      {:reject, rejected(operation, "invalid_stay")}
    end
  end

  defp validate_rooms(operation) do
    case Map.fetch(operation, "rooms") do
      {:ok, rooms} when is_list(rooms) and rooms != [] ->
        normalize_rooms(operation, rooms)

      _other ->
        {:reject, rejected(operation, "invalid_rooms")}
    end
  end

  defp normalize_rooms(operation, rooms) do
    normalized =
      Enum.reduce_while(rooms, [], fn room, acc ->
        with %{} <- room,
             {:ok, room_id} <- fetch_string(room, "room_id"),
             {:ok, nightly_rate_cents} <-
               fetch_positive_integer(room, "nightly_rate_cents", "invalid_rooms") do
          {:cont, [%{room_id: room_id, nightly_rate_cents: nightly_rate_cents} | acc]}
        else
          _other -> {:halt, :invalid}
        end
      end)

    case normalized do
      :invalid ->
        {:reject, rejected(operation, "invalid_rooms")}

      rooms ->
        rooms = Enum.reverse(rooms)
        room_ids = Enum.map(rooms, & &1.room_id)

        if Enum.uniq(room_ids) == room_ids do
          {:ok, rooms}
        else
          {:reject, rejected(operation, "invalid_rooms")}
        end
    end
  end

  defp validate_rate_plan(operation) do
    case Map.get(operation, "rate_plan") do
      rate_plan when rate_plan in [@flexible, @advance_purchase] ->
        {:ok, rate_plan}

      _other ->
        {:reject, rejected(operation, "invalid_rate_plan")}
    end
  end

  defp calculate_totals(rooms, arrival_on, departure_on, rate_plan) do
    nights = Date.diff(departure_on, arrival_on)

    Enum.reduce(rooms, %{lodging_total_cents: 0, deposit_due_cents: 0}, fn room, totals ->
      lodging_cents = room.nightly_rate_cents * nights
      deposit_cents = deposit_for_room(lodging_cents, rate_plan)

      %{
        lodging_total_cents: totals.lodging_total_cents + lodging_cents,
        deposit_due_cents: totals.deposit_due_cents + deposit_cents
      }
    end)
  end

  defp deposit_for_room(lodging_cents, @flexible), do: div(lodging_cents * 20 + 50, 100)
  defp deposit_for_room(lodging_cents, @advance_purchase), do: lodging_cents

  defp cancellation_settlement(%Group{rate_plan: @flexible} = group, occurred_on) do
    if Date.diff(group.arrival_on, occurred_on) >= 14 do
      {group.deposit_paid_cents, 0}
    else
      {0, group.deposit_paid_cents}
    end
  end

  defp cancellation_settlement(group, _occurred_on), do: {0, group.deposit_paid_cents}

  defp insert_group(attrs) do
    %Group{
      group_id: attrs.group_id,
      guest_id: attrs.guest_id,
      property_id: attrs.property_id,
      booked_on: attrs.booked_on,
      arrival_on: attrs.arrival_on,
      departure_on: attrs.departure_on,
      rate_plan: attrs.rate_plan,
      status: @active,
      lodging_total_cents: attrs.lodging_total_cents,
      deposit_due_cents: attrs.deposit_due_cents,
      deposit_paid_cents: 0,
      cash_refunded_cents: 0,
      cash_retained_cents: 0,
      revision: 1
    }
    |> Repo.insert()
  end

  defp insert_rooms(group, rooms) do
    rooms
    |> Enum.with_index()
    |> Enum.each(fn {room, position} ->
      Repo.insert!(%Room{
        reservation_id: group.id,
        room_id: room.room_id,
        nightly_rate_cents: room.nightly_rate_cents,
        position: position
      })
    end)

    :ok
  end

  defp present_group(group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      status: group.status,
      rooms:
        Enum.map(group.rooms, fn room ->
          %{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents
          }
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: outstanding_deposit_cents(group)
    }
  end

  defp outstanding_deposit_cents(%Group{status: @active} = group) do
    max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  end

  defp outstanding_deposit_cents(%Group{}), do: 0

  defp sum_groups(field, filters \\ []) do
    Group
    |> where(^filters)
    |> select([g], coalesce(sum(field(g, ^field)), 0))
    |> Repo.one()
  end

  defp fetch_string(map, field) do
    case Map.fetch(map, field) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:reject, rejected(map, "invalid_operation")}
    end
  end

  defp fetch_positive_integer(map, field, code) do
    case Map.fetch(map, field) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:reject, rejected(map, code)}
    end
  end

  defp fetch_date(map, field, code) do
    case Map.fetch(map, field) do
      {:ok, value} when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> {:reject, rejected(map, code)}
        end

      _other ->
        {:reject, rejected(map, code)}
    end
  end

  defp operation_id(operation) when is_map(operation), do: Map.get(operation, "operation_id")
  defp operation_id(_operation), do: nil

  defp rejected(operation, code) do
    %{
      operation_id: operation_id(operation),
      status: "rejected",
      code: code
    }
  end
end
