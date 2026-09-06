defmodule GroupStay.Operations do
  import Ecto.Query

  alias GroupStay.{Group, Repo, Room}

  @rate_plans ["flexible", "advance_purchase"]
  @max_sqlite_integer 9_223_372_036_854_775_807

  def process_batch(operations) do
    Enum.map(operations, fn operation ->
      case Repo.transaction(fn -> process_operation(operation) end, mode: :immediate) do
        {:ok, result} -> result
        {:error, result} -> result
      end
    end)
  end

  def get_group(group_id) when is_binary(group_id) do
    Group
    |> Repo.get_by(group_id: group_id)
    |> case do
      nil -> nil
      group -> Repo.preload(group, rooms: from(r in Room, order_by: r.position))
    end
  end

  def get_group(_group_id), do: nil

  def ledger do
    Repo.all(Group)
    |> Enum.reduce(
      %{cash_held_cents: 0, cash_refunded_cents: 0, cash_retained_cents: 0},
      fn group, totals ->
        %{
          cash_held_cents:
            totals.cash_held_cents +
              if(group.status == "active", do: group.deposit_paid_cents, else: 0),
          cash_refunded_cents: totals.cash_refunded_cents + group.refunded_cents,
          cash_retained_cents: totals.cash_retained_cents + group.retained_cents
        }
      end
    )
  end

  def outstanding(%Group{status: "active"} = group) do
    group.deposit_due_cents - group.deposit_paid_cents
  end

  def outstanding(%Group{}), do: 0

  defp process_operation(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp process_operation(%{"type" => type} = operation)
       when type in ["record_cash_payment", "reschedule_group", "cancel_group"] do
    with {:ok, operation_id} <- required_string(operation, "operation_id"),
         {:ok, group_id} <- required_string(operation, "group_id") do
      case Repo.get_by(Group, group_id: group_id) do
        nil -> rejected(operation_id, "group_not_found")
        group -> process_existing(operation, operation_id, group)
      end
    else
      _ -> rejected(operation_id(operation), "invalid_operation")
    end
  end

  defp process_operation(operation) when is_map(operation) do
    rejected(operation_id(operation), "invalid_operation")
  end

  defp process_operation(_operation), do: rejected(nil, "invalid_operation")

  defp open_group(operation) do
    with {:ok, operation_id} <- required_string(operation, "operation_id"),
         {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, guest_id} <- required_string(operation, "guest_id"),
         {:ok, property_id} <- required_string(operation, "property_id"),
         {:ok, occurred_on_value} <- required_value(operation, "occurred_on"),
         {:ok, arrival_value} <- required_value(operation, "arrival_on"),
         {:ok, departure_value} <- required_value(operation, "departure_on"),
         {:ok, rate_plan} <- required_value(operation, "rate_plan"),
         {:ok, rooms} <- required_value(operation, "rooms") do
      cond do
        Repo.exists?(from g in Group, where: g.group_id == ^group_id) ->
          rejected(operation_id, "group_already_exists")

        rate_plan not in @rate_plans ->
          rejected(operation_id, "invalid_rate_plan")

        true ->
          create_group(operation_id, %{
            group_id: group_id,
            guest_id: guest_id,
            property_id: property_id,
            occurred_on: occurred_on_value,
            arrival_on: arrival_value,
            departure_on: departure_value,
            rate_plan: rate_plan,
            rooms: rooms
          })
      end
    else
      _ -> rejected(operation_id(operation), "invalid_operation")
    end
  end

  defp create_group(operation_id, attrs) do
    with {:ok, booked_on} <- parse_date(attrs.occurred_on),
         {:ok, arrival_on} <- parse_date(attrs.arrival_on),
         {:ok, departure_on} <- parse_date(attrs.departure_on),
         true <- Date.compare(departure_on, arrival_on) == :gt do
      nights = Date.diff(departure_on, arrival_on)

      case validate_rooms(attrs.rooms, nights, attrs.rate_plan) do
        {:ok, rooms, lodging_total, deposit_due} ->
          persist_group(
            operation_id,
            attrs,
            booked_on,
            arrival_on,
            departure_on,
            rooms,
            lodging_total,
            deposit_due
          )

        :error ->
          rejected(operation_id, "invalid_rooms")
      end
    else
      _ -> rejected(operation_id, "invalid_stay")
    end
  end

  defp persist_group(
         operation_id,
         attrs,
         booked_on,
         arrival_on,
         departure_on,
         rooms,
         lodging_total,
         deposit_due
       ) do
    group_attrs = %{
      group_id: attrs.group_id,
      guest_id: attrs.guest_id,
      property_id: attrs.property_id,
      booked_on: booked_on,
      arrival_on: arrival_on,
      departure_on: departure_on,
      rate_plan: attrs.rate_plan,
      lodging_total_cents: lodging_total,
      deposit_due_cents: deposit_due
    }

    case %Group{} |> Group.changeset(group_attrs) |> Repo.insert() do
      {:ok, group} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        room_rows =
          Enum.map(rooms, fn room ->
            Map.merge(room, %{
              id: Ecto.UUID.generate(),
              group_ref: group.id,
              inserted_at: now,
              updated_at: now
            })
          end)

        {room_count, _} = Repo.insert_all(Room, room_rows)

        if room_count == length(room_rows) do
          applied(operation_id, %{
            group_id: group.group_id,
            deposit_due_cents: group.deposit_due_cents,
            revision: group.revision
          })
        else
          Repo.rollback(rejected(operation_id, "invalid_rooms"))
        end

      {:error, changeset} ->
        code =
          if changeset.errors[:group_id], do: "group_already_exists", else: "invalid_operation"

        rejected(operation_id, code)
    end
  end

  defp process_existing(operation, operation_id, group) do
    with :ok <- validate_expected_revision(operation, group) do
      case operation["type"] do
        "record_cash_payment" -> record_cash_payment(operation, operation_id, group)
        "reschedule_group" -> reschedule_group(operation, operation_id, group)
        "cancel_group" -> cancel_group(operation, operation_id, group)
      end
    else
      {:stale, expected} -> stale(operation_id, group, expected)
      :invalid -> rejected(operation_id, "invalid_operation")
    end
  end

  defp record_cash_payment(operation, operation_id, group) do
    with {:ok, occurred_value} <- required_value(operation, "occurred_on"),
         {:ok, _occurred_on} <- parse_date(occurred_value),
         {:ok, amount} <- required_value(operation, "amount_cents") do
      cond do
        group.status != "active" ->
          rejected(operation_id, "group_not_active")

        not (is_integer(amount) and amount > 0) ->
          rejected(operation_id, "invalid_amount")

        amount > outstanding(group) ->
          rejected(operation_id, "payment_exceeds_outstanding")

        true ->
          {:ok, updated} =
            group
            |> Group.changeset(%{
              deposit_paid_cents: group.deposit_paid_cents + amount,
              revision: group.revision + 1
            })
            |> Repo.update()

          applied(operation_id, %{
            group_id: updated.group_id,
            amount_cents: amount,
            outstanding_deposit_cents: outstanding(updated),
            revision: updated.revision
          })
      end
    else
      _ -> rejected(operation_id, "invalid_operation")
    end
  end

  defp reschedule_group(operation, operation_id, group) do
    with {:ok, occurred_value} <- required_value(operation, "occurred_on"),
         {:ok, arrival_value} <- required_value(operation, "new_arrival_on") do
      cond do
        group.status != "active" ->
          rejected(operation_id, "group_not_active")

        true ->
          move_group(operation_id, group, occurred_value, arrival_value)
      end
    else
      _ -> rejected(operation_id, "invalid_operation")
    end
  end

  defp move_group(operation_id, group, occurred_value, arrival_value) do
    with {:ok, occurred_on} <- parse_date(occurred_value),
         {:ok, new_arrival_on} <- parse_date(arrival_value),
         true <- Date.compare(new_arrival_on, occurred_on) == :gt do
      new_departure_on = Date.add(new_arrival_on, Date.diff(group.departure_on, group.arrival_on))

      {:ok, updated} =
        group
        |> Group.changeset(%{
          arrival_on: new_arrival_on,
          departure_on: new_departure_on,
          revision: group.revision + 1
        })
        |> Repo.update()

      applied(operation_id, %{
        group_id: updated.group_id,
        new_arrival_on: Date.to_iso8601(updated.arrival_on),
        new_departure_on: Date.to_iso8601(updated.departure_on),
        revision: updated.revision
      })
    else
      _ -> rejected(operation_id, "invalid_stay")
    end
  end

  defp cancel_group(operation, operation_id, group) do
    with {:ok, occurred_value} <- required_value(operation, "occurred_on") do
      cond do
        group.status != "active" ->
          rejected(operation_id, "group_not_active")

        true ->
          settle_cancellation(operation_id, group, occurred_value)
      end
    else
      _ -> rejected(operation_id, "invalid_operation")
    end
  end

  defp settle_cancellation(operation_id, group, occurred_value) do
    case parse_date(occurred_value) do
      {:ok, occurred_on} ->
        refundable =
          group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred_on) >= 14

        refunded = if refundable, do: group.deposit_paid_cents, else: 0
        retained = if refundable, do: 0, else: group.deposit_paid_cents

        {:ok, updated} =
          group
          |> Group.changeset(%{
            status: "cancelled",
            refunded_cents: refunded,
            retained_cents: retained,
            revision: group.revision + 1
          })
          |> Repo.update()

        applied(operation_id, %{
          group_id: updated.group_id,
          refunded_cents: refunded,
          retained_cents: retained,
          revision: updated.revision
        })

      :error ->
        rejected(operation_id, "invalid_operation")
    end
  end

  defp validate_expected_revision(operation, group) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, expected} when is_integer(expected) and expected > 0 ->
        if expected == group.revision, do: :ok, else: {:stale, expected}

      {:ok, _expected} ->
        :invalid
    end
  end

  defp validate_rooms(rooms, nights, rate_plan) when is_list(rooms) and rooms != [] do
    parsed =
      Enum.with_index(rooms)
      |> Enum.reduce_while([], fn
        {%{"room_id" => room_id, "nightly_rate_cents" => rate}, position}, acc
        when is_binary(room_id) and room_id != "" and is_integer(rate) and rate > 0 ->
          {:cont, [%{room_id: room_id, nightly_rate_cents: rate, position: position} | acc]}

        _, _acc ->
          {:halt, :error}
      end)

    case parsed do
      :error ->
        :error

      rooms ->
        rooms = Enum.reverse(rooms)

        if Enum.uniq_by(rooms, & &1.room_id) == rooms do
          totals =
            Enum.reduce(rooms, {0, 0}, fn room, {lodging_total, deposit_total} ->
              lodging = room.nightly_rate_cents * nights
              deposit = if rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging
              {lodging_total + lodging, deposit_total + deposit}
            end)

          {lodging_total, deposit_due} = totals

          if Enum.all?(rooms, &(&1.nightly_rate_cents <= @max_sqlite_integer)) and
               lodging_total <= @max_sqlite_integer and deposit_due <= @max_sqlite_integer do
            {:ok, rooms, lodging_total, deposit_due}
          else
            :error
          end
        else
          :error
        end
    end
  end

  defp validate_rooms(_rooms, _nights, _rate_plan), do: :error

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_value), do: :error

  defp required_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> :error
    end
  end

  defp required_value(map, key), do: Map.fetch(map, key)

  defp operation_id(%{"operation_id" => operation_id}) when is_binary(operation_id),
    do: operation_id

  defp operation_id(_operation), do: nil

  defp applied(operation_id, fields),
    do: Map.merge(%{operation_id: operation_id, status: "applied"}, fields)

  defp rejected(operation_id, code),
    do: %{operation_id: operation_id, status: "rejected", code: code}

  defp stale(operation_id, group, expected) do
    %{
      operation_id: operation_id,
      status: "rejected",
      code: "stale_revision",
      group_id: group.group_id,
      expected_revision: expected,
      actual_revision: group.revision
    }
  end
end
