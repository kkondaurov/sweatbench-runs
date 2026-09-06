defmodule GroupStay.Groups do
  @moduledoc "The group-deposit domain and its ordered partner operations."

  import Ecto.Query

  alias GroupStay.Groups.{Group, Room}
  alias GroupStay.Repo

  @rate_plans ["flexible", "advance_purchase"]
  @top_level_open ~w(operation_id type occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms)

  def process_batch(operations) do
    Enum.map(operations, &process_operation/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> nil
      group -> Repo.preload(group, :rooms)
    end
  end

  def get_group(_), do: nil

  def ledger do
    groups = Repo.all(Group)

    %{
      cash_held_cents:
        groups
        |> Enum.filter(&(&1.status == "active"))
        |> Enum.map(& &1.deposit_paid_cents)
        |> Enum.sum(),
      cash_refunded_cents: groups |> Enum.map(& &1.cash_refunded_cents) |> Enum.sum(),
      cash_retained_cents: groups |> Enum.map(& &1.cash_retained_cents) |> Enum.sum()
    }
  end

  def group_json(%Group{} = group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: group.booked_on,
      arrival_on: group.arrival_on,
      departure_on: group.departure_on,
      rate_plan: group.rate_plan,
      status: group.status,
      rooms:
        Enum.map(group.rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: outstanding(group)
    }
  end

  defp process_operation(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")

    case validate_envelope(operation) do
      :ok -> transact_operation(operation, operation_id)
      :error -> rejected(operation_id, "invalid_operation")
    end
  end

  defp process_operation(_), do: rejected(nil, "invalid_operation")

  defp validate_envelope(operation) do
    if nonempty_string?(operation["operation_id"]) and nonempty_string?(operation["type"]) do
      :ok
    else
      :error
    end
  end

  defp transact_operation(operation, operation_id) do
    transact_operation(operation, operation_id, 0)
  end

  defp transact_operation(operation, operation_id, attempt) do
    try do
      case Repo.transaction(fn -> dispatch(operation, operation_id) end) do
        {:ok, result} -> result
        {:error, result} when is_map(result) -> result
        {:error, _reason} -> rejected(operation_id, "invalid_operation")
      end
    rescue
      Ecto.StaleEntryError -> handle_concurrent_update(operation, operation_id, attempt)
    end
  end

  defp handle_concurrent_update(operation, operation_id, attempt) do
    if Map.has_key?(operation, "expected_revision") do
      case get_group(operation["group_id"]) do
        nil ->
          rejected(operation_id, "group_not_found", operation["group_id"])

        group ->
          rejected(operation_id, "stale_revision", group.group_id, %{
            expected_revision: operation["expected_revision"],
            actual_revision: group.revision
          })
      end
    else
      # Unconditional operations retain their existing behavior under a competing writer.
      if attempt < 3,
        do: transact_operation(operation, operation_id, attempt + 1),
        else: rejected(operation_id, "invalid_operation")
    end
  end

  defp dispatch(%{"type" => "open_group"} = operation, operation_id),
    do: open_group(operation, operation_id)

  defp dispatch(%{"type" => "record_cash_payment"} = operation, operation_id),
    do: with_group(operation, operation_id, &record_cash_payment(&1, operation, operation_id))

  defp dispatch(%{"type" => "reschedule_group"} = operation, operation_id),
    do: with_group(operation, operation_id, &reschedule_group(&1, operation, operation_id))

  defp dispatch(%{"type" => "cancel_group"} = operation, operation_id),
    do: with_group(operation, operation_id, &cancel_group(&1, operation, operation_id))

  defp dispatch(_operation, operation_id), do: reject(operation_id, "invalid_operation")

  defp open_group(operation, operation_id) do
    cond do
      not Enum.all?(@top_level_open, &Map.has_key?(operation, &1)) ->
        reject(operation_id, "invalid_operation")

      not valid_open_identifiers?(operation) ->
        reject(operation_id, "invalid_operation")

      Repo.exists?(from g in Group, where: g.group_id == ^operation["group_id"]) ->
        reject(operation_id, "group_already_exists", operation["group_id"])

      operation["rate_plan"] not in @rate_plans ->
        reject(operation_id, "invalid_rate_plan", operation["group_id"])

      true ->
        create_group(operation, operation_id)
    end
  end

  defp create_group(operation, operation_id) do
    with {:ok, booked_on} <- parse_date(operation["occurred_on"]),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         true <- Date.compare(arrival_on, departure_on) == :lt || :invalid_stay,
         {:ok, rooms} <- validate_rooms(operation["rooms"]) do
      nights = Date.diff(departure_on, arrival_on)
      lodging_total = rooms |> Enum.map(&(&1.nightly_rate_cents * nights)) |> Enum.sum()

      deposit_due =
        rooms
        |> Enum.map(fn room ->
          lodging = room.nightly_rate_cents * nights
          if operation["rate_plan"] == "flexible", do: div(lodging * 20 + 50, 100), else: lodging
        end)
        |> Enum.sum()

      attrs = %{
        group_id: operation["group_id"],
        guest_id: operation["guest_id"],
        property_id: operation["property_id"],
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: operation["rate_plan"],
        lodging_total_cents: lodging_total,
        deposit_due_cents: deposit_due
      }

      case Repo.insert(Group.changeset(%Group{}, attrs)) do
        {:ok, group} ->
          now = DateTime.utc_now()

          room_rows =
            rooms
            |> Enum.with_index()
            |> Enum.map(fn {room, position} ->
              room
              |> Map.put(:group_id, group.id)
              |> Map.put(:position, position)
              |> Map.put(:inserted_at, now)
              |> Map.put(:updated_at, now)
            end)

          {_count, nil} = Repo.insert_all(Room, room_rows)

          %{
            operation_id: operation_id,
            status: "applied",
            group_id: group.group_id,
            deposit_due_cents: group.deposit_due_cents,
            revision: group.revision
          }

        {:error, changeset} ->
          if changeset.errors[:group_id],
            do: reject(operation_id, "group_already_exists", operation["group_id"]),
            else: reject(operation_id, "invalid_operation")
      end
    else
      :invalid_stay -> reject(operation_id, "invalid_stay", operation["group_id"])
      {:error, :date} -> reject(operation_id, "invalid_stay", operation["group_id"])
      {:error, :rooms} -> reject(operation_id, "invalid_rooms", operation["group_id"])
    end
  end

  defp with_group(operation, operation_id, function) do
    group_id = operation["group_id"]

    if not nonempty_string?(group_id) do
      reject(operation_id, "invalid_operation")
    else
      case Repo.get_by(Group, group_id: group_id) do
        nil -> reject(operation_id, "group_not_found", group_id)
        group -> check_revision(group, operation, operation_id, function)
      end
    end
  end

  defp check_revision(group, operation, operation_id, function) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] != group.revision do
      reject(operation_id, "stale_revision", group.group_id, %{
        expected_revision: operation["expected_revision"],
        actual_revision: group.revision
      })
    else
      function.(group)
    end
  end

  defp record_cash_payment(group, operation, operation_id) do
    amount = operation["amount_cents"]

    cond do
      not Map.has_key?(operation, "occurred_on") or not Map.has_key?(operation, "amount_cents") ->
        reject(operation_id, "invalid_operation")

      group.status != "active" ->
        reject(operation_id, "group_not_active", group.group_id)

      not valid_date?(operation["occurred_on"]) ->
        reject(operation_id, "invalid_operation")

      not (is_integer(amount) and amount > 0) ->
        reject(operation_id, "invalid_amount", group.group_id)

      amount > outstanding(group) ->
        reject(operation_id, "payment_exceeds_outstanding", group.group_id)

      true ->
        group = update_group!(group, %{deposit_paid_cents: group.deposit_paid_cents + amount})

        %{
          operation_id: operation_id,
          status: "applied",
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: outstanding(group),
          revision: group.revision
        }
    end
  end

  defp reschedule_group(group, operation, operation_id) do
    cond do
      not Map.has_key?(operation, "occurred_on") or not Map.has_key?(operation, "new_arrival_on") ->
        reject(operation_id, "invalid_operation")

      group.status != "active" ->
        reject(operation_id, "group_not_active", group.group_id)

      true ->
        apply_reschedule(group, operation, operation_id)
    end
  end

  defp apply_reschedule(group, operation, operation_id) do
    with {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"]),
         true <- Date.compare(new_arrival_on, occurred_on) == :gt do
      stay_length = Date.diff(group.departure_on, group.arrival_on)
      new_departure_on = Date.add(new_arrival_on, stay_length)

      group =
        update_group!(group, %{arrival_on: new_arrival_on, departure_on: new_departure_on})

      %{
        operation_id: operation_id,
        status: "applied",
        group_id: group.group_id,
        new_arrival_on: new_arrival_on,
        new_departure_on: new_departure_on,
        revision: group.revision
      }
    else
      _ -> reject(operation_id, "invalid_stay", group.group_id)
    end
  end

  defp cancel_group(group, operation, operation_id) do
    cond do
      not Map.has_key?(operation, "occurred_on") ->
        reject(operation_id, "invalid_operation")

      group.status != "active" ->
        reject(operation_id, "group_not_active", group.group_id)

      true ->
        case parse_date(operation["occurred_on"]) do
          {:ok, occurred_on} -> apply_cancellation(group, occurred_on, operation_id)
          {:error, :date} -> reject(operation_id, "invalid_operation")
        end
    end
  end

  defp apply_cancellation(group, occurred_on, operation_id) do
    refundable = group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred_on) >= 14
    refunded = if refundable, do: group.deposit_paid_cents, else: 0
    retained = if refundable, do: 0, else: group.deposit_paid_cents

    group =
      update_group!(group, %{
        status: "cancelled",
        cash_refunded_cents: refunded,
        cash_retained_cents: retained
      })

    %{
      operation_id: operation_id,
      status: "applied",
      group_id: group.group_id,
      refunded_cents: refunded,
      retained_cents: retained,
      revision: group.revision
    }
  end

  defp update_group!(group, attrs) do
    group
    |> Group.changeset(attrs)
    |> Ecto.Changeset.optimistic_lock(:revision)
    |> Repo.update!()
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn
        %{"room_id" => room_id, "nightly_rate_cents" => rate} ->
          nonempty_string?(room_id) and is_integer(rate) and rate > 0

        _ ->
          false
      end)

    room_ids = Enum.map(rooms, &Map.get(&1, "room_id"))

    if valid and Enum.uniq(room_ids) == room_ids do
      {:ok,
       Enum.map(rooms, fn room ->
         %{room_id: room["room_id"], nightly_rate_cents: room["nightly_rate_cents"]}
       end)}
    else
      {:error, :rooms}
    end
  end

  defp validate_rooms(_), do: {:error, :rooms}

  defp valid_open_identifiers?(operation) do
    Enum.all?(~w(group_id guest_id property_id), &nonempty_string?(operation[&1]))
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :date}
    end
  end

  defp parse_date(_), do: {:error, :date}

  defp valid_date?(value), do: match?({:ok, _}, parse_date(value))
  defp nonempty_string?(value), do: is_binary(value) and byte_size(value) > 0

  defp outstanding(%Group{status: "active"} = group),
    do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  defp outstanding(%Group{}), do: 0

  defp reject(operation_id, code, group_id \\ nil, extra \\ %{}) do
    Repo.rollback(rejected(operation_id, code, group_id, extra))
  end

  defp rejected(operation_id, code, group_id \\ nil, extra \\ %{}) do
    %{operation_id: operation_id, status: "rejected", code: code}
    |> maybe_put(:group_id, group_id)
    |> Map.merge(extra)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
