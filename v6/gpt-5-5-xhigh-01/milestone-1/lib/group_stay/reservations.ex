defmodule GroupStay.Reservations do
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.Group
  alias GroupStay.Reservations.LedgerEntry
  alias GroupStay.Reservations.Room

  @active "active"
  @cancelled "cancelled"
  @flexible "flexible"
  @advance_purchase "advance_purchase"
  @cash_payment "cash_payment"
  @cash_refund "cash_refund"
  @cash_retention "cash_retention"

  def submit_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation_transaction/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    group_id
    |> fetch_group()
    |> preload_rooms()
  end

  def get_group(_group_id), do: nil

  def group_data(%Group{} = group) do
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
      rooms: Enum.map(group.rooms, &room_data/1),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: outstanding_deposit_cents(group)
    }
  end

  def ledger_totals do
    totals =
      LedgerEntry
      |> group_by([entry], entry.entry_type)
      |> select([entry], {entry.entry_type, sum(entry.amount_cents)})
      |> Repo.all()
      |> Map.new(fn {entry_type, amount} -> {entry_type, amount || 0} end)

    refunded_cents = Map.get(totals, @cash_refund, 0)
    retained_cents = Map.get(totals, @cash_retention, 0)
    payment_cents = Map.get(totals, @cash_payment, 0)

    %{
      cash_held_cents: max(payment_cents - refunded_cents - retained_cents, 0),
      cash_refunded_cents: refunded_cents,
      cash_retained_cents: retained_cents
    }
  end

  defp apply_operation_transaction(operation) do
    case Repo.transaction(fn ->
           case apply_operation(operation) do
             {:ok, result} -> result
             {:error, result} -> Repo.rollback(result)
           end
         end) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp apply_operation(operation) do
    with {:ok, metadata} <- parse_common(operation) do
      case metadata.type do
        "open_group" -> open_group(metadata)
        "record_cash_payment" -> record_cash_payment(metadata)
        "reschedule_group" -> reschedule_group(metadata)
        "cancel_group" -> cancel_group(metadata)
        _type -> reject(metadata, "invalid_operation")
      end
    end
  end

  defp parse_common(operation) when is_map(operation) do
    operation_id = operation["operation_id"]
    type = operation["type"]

    with true <- present_string?(operation_id),
         true <- present_string?(type),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]) do
      {:ok,
       %{
         operation: operation,
         operation_id: operation_id,
         type: type,
         occurred_on: occurred_on
       }}
    else
      _ -> reject(operation, "invalid_operation")
    end
  end

  defp parse_common(operation), do: reject(operation, "invalid_operation")

  defp open_group(%{operation: operation} = metadata) do
    with :ok <- require_open_identifiers(operation, metadata),
         :ok <- ensure_group_unique(operation["group_id"], metadata),
         {:ok, arrival_on, departure_on, nights} <- parse_stay_dates(operation, metadata),
         :ok <- validate_rate_plan(operation["rate_plan"], metadata),
         {:ok, rooms} <- validate_rooms(operation["rooms"], metadata) do
      lodging_total_cents = lodging_total_cents(rooms, nights)
      deposit_due_cents = deposit_due_cents(rooms, nights, operation["rate_plan"])

      group =
        %Group{}
        |> Group.changeset(%{
          group_id: operation["group_id"],
          guest_id: operation["guest_id"],
          property_id: operation["property_id"],
          booked_on: metadata.occurred_on,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: operation["rate_plan"],
          status: @active,
          lodging_total_cents: lodging_total_cents,
          deposit_due_cents: deposit_due_cents,
          deposit_paid_cents: 0,
          revision: 1
        })
        |> Repo.insert()

      case group do
        {:ok, group} ->
          Enum.each(rooms, fn room ->
            %Room{}
            |> Room.changeset(%{
              group_id: group.id,
              room_id: room.room_id,
              nightly_rate_cents: room.nightly_rate_cents,
              position: room.position
            })
            |> Repo.insert!()
          end)

          apply_result(metadata, %{
            group_id: group.group_id,
            deposit_due_cents: group.deposit_due_cents,
            revision: group.revision
          })

        {:error, _changeset} ->
          reject(metadata, "group_already_exists")
      end
    end
  end

  defp record_cash_payment(metadata) do
    with {:ok, group} <- fetch_existing_group_for_update(metadata),
         :ok <- ensure_active(group, metadata),
         {:ok, amount_cents} <- payment_amount(metadata),
         :ok <- ensure_payment_within_outstanding(group, amount_cents, metadata) do
      new_deposit_paid_cents = group.deposit_paid_cents + amount_cents
      new_revision = group.revision + 1

      group =
        update_group!(group, %{
          deposit_paid_cents: new_deposit_paid_cents,
          revision: new_revision
        })

      insert_ledger_entry!(group, metadata, @cash_payment, amount_cents)

      apply_result(metadata, %{
        group_id: group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: outstanding_deposit_cents(group),
        revision: group.revision
      })
    end
  end

  defp reschedule_group(metadata) do
    with {:ok, group} <- fetch_existing_group_for_update(metadata),
         :ok <- ensure_active(group, metadata),
         {:ok, new_arrival_on} <- parse_reschedule_arrival(metadata) do
      shift_days = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift_days)

      group =
        update_group!(group, %{
          arrival_on: new_arrival_on,
          departure_on: new_departure_on,
          revision: group.revision + 1
        })

      apply_result(metadata, %{
        group_id: group.group_id,
        new_arrival_on: Date.to_iso8601(group.arrival_on),
        new_departure_on: Date.to_iso8601(group.departure_on),
        revision: group.revision
      })
    end
  end

  defp cancel_group(metadata) do
    with {:ok, group} <- fetch_existing_group_for_update(metadata),
         :ok <- ensure_active(group, metadata) do
      {refunded_cents, retained_cents} = cancellation_settlement(group, metadata.occurred_on)

      group =
        update_group!(group, %{
          status: @cancelled,
          revision: group.revision + 1
        })

      insert_ledger_entry!(group, metadata, @cash_refund, refunded_cents)
      insert_ledger_entry!(group, metadata, @cash_retention, retained_cents)

      apply_result(metadata, %{
        group_id: group.group_id,
        refunded_cents: refunded_cents,
        retained_cents: retained_cents,
        revision: group.revision
      })
    end
  end

  defp require_open_identifiers(operation, metadata) do
    required_fields = ["group_id", "guest_id", "property_id"]

    if Enum.all?(required_fields, &present_string?(operation[&1])) do
      :ok
    else
      reject(metadata, "invalid_operation")
    end
  end

  defp ensure_group_unique(group_id, metadata) do
    if fetch_group(group_id) do
      reject(metadata, "group_already_exists")
    else
      :ok
    end
  end

  defp parse_stay_dates(operation, metadata) do
    with {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         nights when nights > 0 <- Date.diff(departure_on, arrival_on) do
      {:ok, arrival_on, departure_on, nights}
    else
      _ -> reject(metadata, "invalid_stay")
    end
  end

  defp validate_rate_plan(rate_plan, _metadata) when rate_plan in [@flexible, @advance_purchase],
    do: :ok

  defp validate_rate_plan(_rate_plan, metadata), do: reject(metadata, "invalid_rate_plan")

  defp validate_rooms(rooms, metadata) when is_list(rooms) and rooms != [] do
    rooms
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn {room, position},
                                                     {:ok, valid_rooms, room_ids} ->
      case validate_room(room, position, room_ids) do
        {:ok, valid_room} ->
          {:cont, {:ok, [valid_room | valid_rooms], MapSet.put(room_ids, valid_room.room_id)}}

        :error ->
          {:halt, reject(metadata, "invalid_rooms")}
      end
    end)
    |> case do
      {:ok, valid_rooms, _room_ids} -> {:ok, Enum.reverse(valid_rooms)}
      {:error, _result} = error -> error
    end
  end

  defp validate_rooms(_rooms, metadata), do: reject(metadata, "invalid_rooms")

  defp validate_room(room, position, room_ids) when is_map(room) do
    room_id = room["room_id"]
    nightly_rate_cents = room["nightly_rate_cents"]

    cond do
      not present_string?(room_id) ->
        :error

      not (is_integer(nightly_rate_cents) and nightly_rate_cents >= 0) ->
        :error

      MapSet.member?(room_ids, room_id) ->
        :error

      true ->
        {:ok, %{room_id: room_id, nightly_rate_cents: nightly_rate_cents, position: position}}
    end
  end

  defp validate_room(_room, _position, _room_ids), do: :error

  defp fetch_existing_group_for_update(%{operation: operation} = metadata) do
    group_id = operation["group_id"]

    if present_string?(group_id) do
      case fetch_group(group_id) do
        nil -> reject(metadata, "group_not_found")
        group -> ensure_current_revision(group, metadata)
      end
    else
      reject(metadata, "invalid_operation")
    end
  end

  defp ensure_current_revision(group, %{operation: operation} = metadata) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        {:ok, group}

      {:ok, expected_revision} when expected_revision == group.revision ->
        {:ok, group}

      {:ok, expected_revision} ->
        {:error,
         %{
           operation_id: metadata.operation_id,
           status: "rejected",
           code: "stale_revision",
           group_id: group.group_id,
           expected_revision: expected_revision,
           actual_revision: group.revision
         }}
    end
  end

  defp ensure_active(%Group{status: @active}, _metadata), do: :ok
  defp ensure_active(%Group{}, metadata), do: reject(metadata, "group_not_active")

  defp payment_amount(%{operation: operation} = metadata) do
    case Map.fetch(operation, "amount_cents") do
      {:ok, amount_cents} when is_integer(amount_cents) and amount_cents > 0 ->
        {:ok, amount_cents}

      {:ok, _amount_cents} ->
        reject(metadata, "invalid_amount")

      :error ->
        reject(metadata, "invalid_operation")
    end
  end

  defp ensure_payment_within_outstanding(group, amount_cents, metadata) do
    if amount_cents <= outstanding_deposit_cents(group) do
      :ok
    else
      reject(metadata, "payment_exceeds_outstanding")
    end
  end

  defp parse_reschedule_arrival(%{operation: operation, occurred_on: occurred_on} = metadata) do
    with {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"]),
         :gt <- Date.compare(new_arrival_on, occurred_on) do
      {:ok, new_arrival_on}
    else
      _ -> reject(metadata, "invalid_stay")
    end
  end

  defp cancellation_settlement(%Group{rate_plan: @advance_purchase} = group, _occurred_on) do
    {0, group.deposit_paid_cents}
  end

  defp cancellation_settlement(%Group{rate_plan: @flexible} = group, occurred_on) do
    if Date.diff(group.arrival_on, occurred_on) >= 14 do
      {group.deposit_paid_cents, 0}
    else
      {0, group.deposit_paid_cents}
    end
  end

  defp lodging_total_cents(rooms, nights) do
    Enum.reduce(rooms, 0, fn room, total ->
      total + room.nightly_rate_cents * nights
    end)
  end

  defp deposit_due_cents(rooms, nights, @flexible) do
    Enum.reduce(rooms, 0, fn room, total ->
      lodging_cents = room.nightly_rate_cents * nights
      total + percentage_cents(lodging_cents, 20)
    end)
  end

  defp deposit_due_cents(rooms, nights, @advance_purchase) do
    lodging_total_cents(rooms, nights)
  end

  defp percentage_cents(amount_cents, percent) do
    div(amount_cents * percent + 50, 100)
  end

  defp outstanding_deposit_cents(%Group{status: @active} = group) do
    max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  end

  defp outstanding_deposit_cents(%Group{}), do: 0

  defp update_group!(group, attrs) do
    group
    |> Group.changeset(attrs)
    |> Repo.update!()
  end

  defp insert_ledger_entry!(_group, _metadata, _entry_type, 0), do: :ok

  defp insert_ledger_entry!(group, metadata, entry_type, amount_cents) do
    %LedgerEntry{}
    |> LedgerEntry.changeset(%{
      group_id: group.id,
      operation_id: metadata.operation_id,
      entry_type: entry_type,
      amount_cents: amount_cents,
      occurred_on: metadata.occurred_on
    })
    |> Repo.insert!()
  end

  defp apply_result(metadata, fields) do
    {:ok,
     metadata
     |> base_result("applied")
     |> Map.merge(fields)}
  end

  defp reject(metadata_or_operation, code) do
    {:error,
     metadata_or_operation
     |> base_result("rejected")
     |> Map.put(:code, code)}
  end

  defp base_result(%{operation_id: operation_id}, status) when is_binary(operation_id) do
    %{operation_id: operation_id, status: status}
  end

  defp base_result(operation, status) when is_map(operation) do
    operation_id =
      case operation["operation_id"] do
        operation_id when is_binary(operation_id) -> operation_id
        _other -> nil
      end

    %{operation_id: operation_id, status: status}
  end

  defp base_result(_operation, status), do: %{operation_id: nil, status: status}

  defp room_data(room) do
    %{
      room_id: room.room_id,
      nightly_rate_cents: room.nightly_rate_cents
    }
  end

  defp fetch_group(group_id) do
    Repo.get_by(Group, group_id: group_id)
  end

  defp preload_rooms(nil), do: nil

  defp preload_rooms(%Group{} = group) do
    rooms_query = from room in Room, order_by: [asc: room.position]
    Repo.preload(group, rooms: rooms_query)
  end

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_value), do: :error

  defp present_string?(value), do: is_binary(value) and value != ""
end
