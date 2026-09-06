defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations in batch order and reports the outcome of each.

  Every operation runs in its own transaction. A rejected operation leaves the
  database exactly as it was and does not stop later operations, while an
  applied operation's changes are visible to the operations that follow it.
  """

  import Ecto.Changeset

  alias GroupStay.Groups.{CashPayment, Group, Room}
  alias GroupStay.Repo

  @operation_types %{
    "open_group" => :open_group,
    "record_cash_payment" => :record_cash_payment,
    "reschedule_group" => :reschedule_group,
    "cancel_group" => :cancel_group
  }

  @rate_plans ~w(flexible advance_purchase)
  @flexible_deposit_percent 20
  @refund_window_days 14

  @doc """
  Processes operations in order, returning one result map per operation.
  """
  def submit_operations(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  defp process_operation(raw) do
    case parse_operation(raw) do
      {:ok, op} -> run(op)
      {:error, operation_id} -> rejected(operation_id, "invalid_operation")
    end
  end

  defp run(op) do
    {:ok, result} = Repo.transaction(fn -> apply_operation(op) end)
    result
  end

  # Applying operations

  defp apply_operation(%{type: :open_group} = op) do
    with :ok <- ensure_group_absent(op),
         {:ok, stay} <- parse_stay(op),
         {:ok, rooms} <- parse_rooms(op.rooms),
         :ok <- ensure_rate_plan(op.rate_plan) do
      open_group(op, stay, rooms)
    else
      {:rejected, code} -> rejected(op.operation_id, code, %{group_id: op.group_id})
    end
  end

  defp apply_operation(%{type: :record_cash_payment} = op) do
    with {:ok, group} <- fetch_group(op),
         :ok <- ensure_expected_revision(op, group),
         :ok <- ensure_active(op, group),
         {:ok, amount_cents} <- ensure_amount(op),
         :ok <- ensure_within_outstanding(op, group, amount_cents) do
      record_cash_payment(op, group, amount_cents)
    else
      {:rejected, result} -> result
    end
  end

  defp apply_operation(%{type: :reschedule_group} = op) do
    with {:ok, group} <- fetch_group(op),
         :ok <- ensure_expected_revision(op, group),
         :ok <- ensure_active(op, group),
         {:ok, new_arrival_on, new_departure_on} <- ensure_reschedule(op, group) do
      reschedule_group(op, group, new_arrival_on, new_departure_on)
    else
      {:rejected, result} -> result
    end
  end

  defp apply_operation(%{type: :cancel_group} = op) do
    with {:ok, group} <- fetch_group(op),
         :ok <- ensure_expected_revision(op, group),
         :ok <- ensure_active(op, group) do
      cancel_group(op, group)
    else
      {:rejected, result} -> result
    end
  end

  # open_group

  defp ensure_group_absent(op) do
    if Repo.get_by(Group, group_id: op.group_id) do
      {:rejected, "group_already_exists"}
    else
      :ok
    end
  end

  defp parse_stay(op) do
    with {:ok, arrival_on} <- parse_date(op.arrival_on),
         {:ok, departure_on} <- parse_date(op.departure_on),
         nights when nights >= 1 <- Date.diff(departure_on, arrival_on) do
      {:ok, %{arrival_on: arrival_on, departure_on: departure_on, nights: nights}}
    else
      _ -> {:rejected, "invalid_stay"}
    end
  end

  defp parse_rooms(rooms) when is_list(rooms) and rooms != [] do
    parsed = Enum.map(rooms, &parse_room/1)

    if Enum.all?(parsed, &match?({:ok, _}, &1)) and unique_room_ids?(parsed) do
      {:ok, Enum.map(parsed, fn {:ok, room} -> room end)}
    else
      {:rejected, "invalid_rooms"}
    end
  end

  defp parse_rooms(_rooms), do: {:rejected, "invalid_rooms"}

  defp parse_room(room) when is_map(room) do
    with {:ok, room_id} when is_binary(room_id) <- fetch(room, "room_id"),
         {:ok, rate} when is_integer(rate) and rate > 0 <- fetch(room, "nightly_rate_cents") do
      {:ok, %{room_id: room_id, nightly_rate_cents: rate}}
    else
      _ -> :error
    end
  end

  defp parse_room(_room), do: :error

  defp unique_room_ids?(parsed) do
    ids = Enum.map(parsed, fn {:ok, room} -> room.room_id end)
    length(ids) == length(Enum.uniq(ids))
  end

  defp ensure_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp ensure_rate_plan(_rate_plan), do: {:rejected, "invalid_rate_plan"}

  defp open_group(op, stay, rooms) do
    deposit_due_cents = deposit_due(stay.nights, rooms, op.rate_plan)

    changeset =
      Group.create_changeset(%Group{}, %{
        group_id: op.group_id,
        guest_id: op.guest_id,
        property_id: op.property_id,
        booked_on: op.occurred_on,
        arrival_on: stay.arrival_on,
        departure_on: stay.departure_on,
        rate_plan: op.rate_plan,
        status: "active",
        revision: 1,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        outstanding_deposit_cents: deposit_due_cents,
        refunded_cents: 0,
        retained_cents: 0
      })

    case Repo.insert(changeset) do
      {:ok, group} ->
        insert_rooms!(group, rooms)

        applied(op.operation_id, %{
          group_id: op.group_id,
          deposit_due_cents: deposit_due_cents,
          revision: group.revision
        })

      {:error, _changeset} ->
        rejected(op.operation_id, "group_already_exists", %{group_id: op.group_id})
    end
  end

  defp insert_rooms!(group, rooms) do
    rooms
    |> Enum.with_index()
    |> Enum.each(fn {room, position} ->
      %Room{}
      |> Room.create_changeset(%{
        group_id: group.id,
        room_id: room.room_id,
        nightly_rate_cents: room.nightly_rate_cents,
        position: position
      })
      |> Repo.insert!()
    end)
  end

  defp deposit_due(nights, rooms, rate_plan) do
    Enum.reduce(rooms, 0, fn room, total ->
      total + room_deposit(room.nightly_rate_cents * nights, rate_plan)
    end)
  end

  defp room_deposit(lodging_cents, "flexible") do
    round_half_up(lodging_cents * @flexible_deposit_percent, 100)
  end

  defp room_deposit(lodging_cents, "advance_purchase"), do: lodging_cents

  defp round_half_up(numerator, denominator) do
    div(numerator + div(denominator, 2), denominator)
  end

  # record_cash_payment

  defp record_cash_payment(op, group, amount_cents) do
    new_revision = group.revision + 1
    outstanding_cents = group.outstanding_deposit_cents - amount_cents

    group
    |> change(
      deposit_paid_cents: group.deposit_paid_cents + amount_cents,
      outstanding_deposit_cents: outstanding_cents,
      revision: new_revision
    )
    |> Repo.update!()

    %CashPayment{}
    |> CashPayment.create_changeset(%{
      group_id: group.id,
      amount_cents: amount_cents,
      occurred_on: op.occurred_on
    })
    |> Repo.insert!()

    applied(op.operation_id, %{
      group_id: op.group_id,
      amount_cents: amount_cents,
      outstanding_deposit_cents: outstanding_cents,
      revision: new_revision
    })
  end

  defp ensure_amount(%{amount_cents: amount_cents})
       when is_integer(amount_cents) and amount_cents > 0 do
    {:ok, amount_cents}
  end

  defp ensure_amount(op) do
    {:rejected, rejected(op.operation_id, "invalid_amount", %{group_id: op.group_id})}
  end

  defp ensure_within_outstanding(op, group, amount_cents) do
    if amount_cents > group.outstanding_deposit_cents do
      {:rejected,
       rejected(op.operation_id, "payment_exceeds_outstanding", %{group_id: op.group_id})}
    else
      :ok
    end
  end

  # reschedule_group

  defp ensure_reschedule(op, group) do
    with {:ok, new_arrival_on} <- parse_date(op.new_arrival_on),
         :gt <- Date.compare(new_arrival_on, op.occurred_on) do
      nights = Date.diff(group.departure_on, group.arrival_on)
      {:ok, new_arrival_on, Date.add(new_arrival_on, nights)}
    else
      _ -> {:rejected, rejected(op.operation_id, "invalid_stay", %{group_id: op.group_id})}
    end
  end

  defp reschedule_group(op, group, new_arrival_on, new_departure_on) do
    new_revision = group.revision + 1

    group
    |> change(arrival_on: new_arrival_on, departure_on: new_departure_on, revision: new_revision)
    |> Repo.update!()

    applied(op.operation_id, %{
      group_id: op.group_id,
      new_arrival_on: new_arrival_on,
      new_departure_on: new_departure_on,
      revision: new_revision
    })
  end

  # cancel_group

  defp cancel_group(op, group) do
    {refunded_cents, retained_cents} = settlement(group, op.occurred_on)
    new_revision = group.revision + 1

    group
    |> change(
      status: "cancelled",
      outstanding_deposit_cents: 0,
      refunded_cents: refunded_cents,
      retained_cents: retained_cents,
      revision: new_revision
    )
    |> Repo.update!()

    applied(op.operation_id, %{
      group_id: op.group_id,
      refunded_cents: refunded_cents,
      retained_cents: retained_cents,
      revision: new_revision
    })
  end

  defp settlement(%Group{rate_plan: "flexible"} = group, occurred_on) do
    if Date.diff(group.arrival_on, occurred_on) >= @refund_window_days do
      {group.deposit_paid_cents, 0}
    else
      {0, group.deposit_paid_cents}
    end
  end

  defp settlement(%Group{} = group, _occurred_on) do
    {0, group.deposit_paid_cents}
  end

  # Shared validation

  defp fetch_group(op) do
    case Repo.get_by(Group, group_id: op.group_id) do
      nil ->
        {:rejected, rejected(op.operation_id, "group_not_found", %{group_id: op.group_id})}

      group ->
        {:ok, group}
    end
  end

  defp ensure_expected_revision(%{expected_revision: nil}, _group), do: :ok

  defp ensure_expected_revision(op, group) do
    if op.expected_revision == group.revision do
      :ok
    else
      {:rejected,
       rejected(op.operation_id, "stale_revision", %{
         group_id: op.group_id,
         expected_revision: op.expected_revision,
         actual_revision: group.revision
       })}
    end
  end

  defp ensure_active(_op, %Group{status: "active"}), do: :ok

  defp ensure_active(op, _group) do
    {:rejected, rejected(op.operation_id, "group_not_active", %{group_id: op.group_id})}
  end

  # Parsing raw operations

  defp parse_operation(raw) when is_map(raw) do
    operation_id = optional_string(raw, "operation_id")

    with {:ok, type} <- fetch_type(raw),
         {:ok, occurred_on} <- fetch_occurred_on(raw),
         {:ok, group_id} <- fetch_string(raw, "group_id"),
         {:ok, fields} <- parse_fields(type, raw) do
      {:ok,
       %{
         type: type,
         operation_id: operation_id,
         occurred_on: occurred_on,
         group_id: group_id
       }
       |> Map.merge(fields)}
    else
      :error -> {:error, operation_id}
    end
  end

  defp parse_operation(_raw), do: {:error, nil}

  defp parse_fields(:open_group, raw) do
    with {:ok, guest_id} <- fetch_string(raw, "guest_id"),
         {:ok, property_id} <- fetch_string(raw, "property_id"),
         {:ok, arrival_on} <- fetch_present(raw, "arrival_on"),
         {:ok, departure_on} <- fetch_present(raw, "departure_on"),
         {:ok, rate_plan} <- fetch_present(raw, "rate_plan"),
         {:ok, rooms} <- fetch_present(raw, "rooms") do
      {:ok,
       %{
         guest_id: guest_id,
         property_id: property_id,
         arrival_on: arrival_on,
         departure_on: departure_on,
         rate_plan: rate_plan,
         rooms: rooms
       }}
    end
  end

  defp parse_fields(:record_cash_payment, raw) do
    with {:ok, amount_cents} <- fetch_present(raw, "amount_cents"),
         {:ok, expected_revision} <- fetch_expected_revision(raw) do
      {:ok, %{amount_cents: amount_cents, expected_revision: expected_revision}}
    end
  end

  defp parse_fields(:reschedule_group, raw) do
    with {:ok, new_arrival_on} <- fetch_present(raw, "new_arrival_on"),
         {:ok, expected_revision} <- fetch_expected_revision(raw) do
      {:ok, %{new_arrival_on: new_arrival_on, expected_revision: expected_revision}}
    end
  end

  defp parse_fields(:cancel_group, raw) do
    with {:ok, expected_revision} <- fetch_expected_revision(raw) do
      {:ok, %{expected_revision: expected_revision}}
    end
  end

  defp fetch_type(raw) do
    with {:ok, type} <- fetch(raw, "type"),
         {:ok, operation_type} <- Map.fetch(@operation_types, type) do
      {:ok, operation_type}
    else
      _ -> :error
    end
  end

  defp fetch_occurred_on(raw) do
    with {:ok, value} <- fetch(raw, "occurred_on"),
         {:ok, date} <- parse_date(value) do
      {:ok, date}
    else
      _ -> :error
    end
  end

  defp fetch_expected_revision(raw) do
    case fetch(raw, "expected_revision") do
      {:ok, value} -> {:ok, value}
      :error -> {:ok, nil}
    end
  end

  defp fetch_present(raw, key) do
    case fetch(raw, key) do
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  defp fetch_string(raw, key) do
    case fetch(raw, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp optional_string(raw, key) do
    case fetch(raw, key) do
      {:ok, value} when is_binary(value) -> value
      _ -> nil
    end
  end

  defp fetch(raw, key) do
    case Map.fetch(raw, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(raw, String.to_atom(key))
    end
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp parse_date(_value), do: :error

  # Results

  defp applied(operation_id, fields) do
    Map.merge(%{operation_id: operation_id, status: "applied"}, fields)
  end

  defp rejected(operation_id, code, extra \\ %{}) do
    Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, extra)
  end
end
