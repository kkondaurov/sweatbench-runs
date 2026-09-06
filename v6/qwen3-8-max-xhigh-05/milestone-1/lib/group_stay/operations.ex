defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations in batch order and reports the outcome of each one.

  Every operation runs in its own transaction. A rejected operation leaves the
  database exactly as it was before the operation began, and processing
  continues with the next operation.
  """

  import Ecto.Query

  alias GroupStay.{Finance, Repo}
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room

  @known_types ~w(open_group record_cash_payment reschedule_group cancel_group)
  @rate_plans ~w(flexible advance_purchase)
  @flexible_deposit_percent 20
  @refund_window_days 14

  @doc """
  Applies each operation in order and returns one result per operation.
  """
  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  @doc """
  Applies a single raw operation and returns its result map.
  """
  def apply_operation(raw) do
    case parse(raw) do
      {:ok, op} -> run(op)
      :invalid -> rejection(operation_id_of(raw), "invalid_operation", group_id_of(raw))
    end
  end

  defp run(op) do
    case Repo.transaction(fn -> apply_op(op) end) do
      {:ok, result} -> result
      {:error, error} -> raise "operation could not be applied: #{inspect(error)}"
    end
  end

  # Parsing

  defp parse(raw) when not is_map(raw), do: :invalid

  defp parse(raw) do
    with {:ok, operation_id} <- fetch_binary(raw, "operation_id"),
         {:ok, type} <- fetch_binary(raw, "type"),
         true <- type in @known_types,
         {:ok, occurred_on} <- fetch_date(raw, "occurred_on"),
         {:ok, fields} <- parse_fields(type, raw) do
      {:ok,
       Map.merge(fields, %{
         operation_id: operation_id,
         type: type,
         occurred_on: occurred_on,
         expected_revision: Map.get(raw, "expected_revision")
       })}
    else
      _ -> :invalid
    end
  end

  defp parse_fields("open_group", raw) do
    with {:ok, group_id} <- fetch_binary(raw, "group_id"),
         {:ok, guest_id} <- fetch_binary(raw, "guest_id"),
         {:ok, property_id} <- fetch_binary(raw, "property_id"),
         {:ok, arrival_on} <- fetch_binary(raw, "arrival_on"),
         {:ok, departure_on} <- fetch_binary(raw, "departure_on"),
         {:ok, rate_plan} <- fetch_binary(raw, "rate_plan"),
         {:ok, rooms} <- fetch_list(raw, "rooms") do
      {:ok,
       %{
         group_id: group_id,
         guest_id: guest_id,
         property_id: property_id,
         arrival_on: arrival_on,
         departure_on: departure_on,
         rate_plan: rate_plan,
         rooms: rooms
       }}
    end
  end

  defp parse_fields("record_cash_payment", raw) do
    with {:ok, group_id} <- fetch_binary(raw, "group_id"),
         {:ok, amount_cents} <- fetch_value(raw, "amount_cents") do
      {:ok, %{group_id: group_id, amount_cents: amount_cents}}
    end
  end

  defp parse_fields("reschedule_group", raw) do
    with {:ok, group_id} <- fetch_binary(raw, "group_id"),
         {:ok, new_arrival_on} <- fetch_binary(raw, "new_arrival_on") do
      {:ok, %{group_id: group_id, new_arrival_on: new_arrival_on}}
    end
  end

  defp parse_fields("cancel_group", raw) do
    with {:ok, group_id} <- fetch_binary(raw, "group_id") do
      {:ok, %{group_id: group_id}}
    end
  end

  defp fetch_binary(raw, key) do
    case Map.fetch(raw, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp fetch_date(raw, key) do
    with {:ok, value} <- fetch_binary(raw, key),
         {:ok, date} <- Date.from_iso8601(value) do
      {:ok, date}
    else
      _ -> :error
    end
  end

  defp fetch_list(raw, key) do
    case Map.fetch(raw, key) do
      {:ok, value} when is_list(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp fetch_value(raw, key) do
    case Map.fetch(raw, key) do
      {:ok, nil} -> :error
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  defp operation_id_of(raw) when is_map(raw) do
    case Map.get(raw, "operation_id") do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp operation_id_of(_), do: nil

  defp group_id_of(raw) when is_map(raw) do
    case Map.get(raw, "group_id") do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp group_id_of(_), do: nil

  # Applying

  defp apply_op(%{type: "open_group"} = op) do
    with :ok <- reject_existing_group(op.group_id),
         {:ok, stay} <- validate_stay(op.arrival_on, op.departure_on),
         {:ok, rooms} <- validate_rooms(op.rooms),
         :ok <- validate_rate_plan(op.rate_plan),
         {:ok, group} <- insert_group(op, stay, rooms) do
      %{
        operation_id: op.operation_id,
        status: "applied",
        group_id: group.group_id,
        deposit_due_cents: group.deposit_due_cents,
        revision: group.revision
      }
    else
      {:reject, code, extras} -> rejection(op.operation_id, code, op.group_id, extras)
    end
  end

  defp apply_op(%{type: "record_cash_payment"} = op) do
    with {:ok, group} <- fetch_group(op.group_id),
         :ok <- check_expected_revision(op, group),
         :ok <- check_active(group),
         :ok <- validate_amount(op.amount_cents),
         :ok <- check_outstanding(group, op.amount_cents),
         {:ok, updated} <- apply_payment(group, op.amount_cents) do
      %{
        operation_id: op.operation_id,
        status: "applied",
        group_id: updated.group_id,
        amount_cents: op.amount_cents,
        outstanding_deposit_cents: updated.deposit_due_cents - updated.deposit_paid_cents,
        revision: updated.revision
      }
    else
      {:reject, code, extras} -> rejection(op.operation_id, code, op.group_id, extras)
    end
  end

  defp apply_op(%{type: "reschedule_group"} = op) do
    with {:ok, group} <- fetch_group(op.group_id),
         :ok <- check_expected_revision(op, group),
         :ok <- check_active(group),
         {:ok, new_arrival_on} <- validate_new_arrival(op.new_arrival_on, op.occurred_on),
         {:ok, updated} <- apply_reschedule(group, new_arrival_on) do
      %{
        operation_id: op.operation_id,
        status: "applied",
        group_id: updated.group_id,
        new_arrival_on: Date.to_iso8601(updated.arrival_on),
        new_departure_on: Date.to_iso8601(updated.departure_on),
        revision: updated.revision
      }
    else
      {:reject, code, extras} -> rejection(op.operation_id, code, op.group_id, extras)
    end
  end

  defp apply_op(%{type: "cancel_group"} = op) do
    with {:ok, group} <- fetch_group(op.group_id),
         :ok <- check_expected_revision(op, group),
         :ok <- check_active(group),
         {:ok, refunded_cents, retained_cents} <- settlement(group, op.occurred_on),
         {:ok, updated} <- apply_cancellation(group, refunded_cents, retained_cents) do
      %{
        operation_id: op.operation_id,
        status: "applied",
        group_id: updated.group_id,
        refunded_cents: refunded_cents,
        retained_cents: retained_cents,
        revision: updated.revision
      }
    else
      {:reject, code, extras} -> rejection(op.operation_id, code, op.group_id, extras)
    end
  end

  # Shared checks

  defp fetch_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:reject, "group_not_found", %{}}
      group -> {:ok, group}
    end
  end

  defp check_expected_revision(%{expected_revision: nil}, _group), do: :ok

  defp check_expected_revision(%{expected_revision: expected}, group) do
    if expected == group.revision do
      :ok
    else
      {:reject, "stale_revision", %{expected_revision: expected, actual_revision: group.revision}}
    end
  end

  defp check_active(%Group{status: "active"}), do: :ok
  defp check_active(_group), do: {:reject, "group_not_active", %{}}

  # Opening

  defp reject_existing_group(group_id) do
    if Repo.exists?(from g in Group, where: g.group_id == ^group_id) do
      {:reject, "group_already_exists", %{}}
    else
      :ok
    end
  end

  defp validate_stay(arrival_raw, departure_raw) do
    with {:ok, arrival_on} <- parse_iso_date(arrival_raw),
         {:ok, departure_on} <- parse_iso_date(departure_raw),
         nights when nights > 0 <- Date.diff(departure_on, arrival_on) do
      {:ok, %{arrival_on: arrival_on, departure_on: departure_on, nights: nights}}
    else
      _ -> {:reject, "invalid_stay", %{}}
    end
  end

  defp parse_iso_date(raw) when is_binary(raw) do
    case Date.from_iso8601(raw) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp parse_iso_date(_), do: :error

  defp validate_rooms(raw_rooms) do
    with {:ok, rooms} <- parse_rooms(raw_rooms),
         true <- rooms != [],
         true <- unique_room_ids?(rooms) do
      {:ok, rooms}
    else
      _ -> {:reject, "invalid_rooms", %{}}
    end
  end

  defp parse_rooms(raw_rooms) do
    raw_rooms
    |> Enum.reduce_while({:ok, []}, &parse_room/2)
    |> case do
      {:ok, rooms} -> {:ok, Enum.reverse(rooms)}
      {:reject, _, _} = reject -> reject
    end
  end

  defp parse_room(raw, {:ok, acc}) when is_map(raw) do
    with {:ok, room_id} <- fetch_binary(raw, "room_id"),
         {:ok, rate} <- fetch_rate(raw) do
      {:cont, {:ok, [%{room_id: room_id, nightly_rate_cents: rate} | acc]}}
    else
      _ -> {:halt, {:reject, "invalid_rooms", %{}}}
    end
  end

  defp parse_room(_raw, _acc), do: {:halt, {:reject, "invalid_rooms", %{}}}

  defp fetch_rate(raw) do
    case Map.fetch(raw, "nightly_rate_cents") do
      {:ok, rate} when is_integer(rate) and rate >= 0 -> {:ok, rate}
      _ -> :error
    end
  end

  defp unique_room_ids?(rooms) do
    ids = Enum.map(rooms, & &1.room_id)
    length(ids) == length(Enum.uniq(ids))
  end

  defp validate_rate_plan(rate_plan) do
    if rate_plan in @rate_plans do
      :ok
    else
      {:reject, "invalid_rate_plan", %{}}
    end
  end

  defp insert_group(op, stay, rooms) do
    lodging_total_cents = lodging_total(stay.nights, rooms)
    deposit_due_cents = deposit_due(op.rate_plan, stay.nights, rooms)

    changeset =
      Group.changeset(%Group{}, %{
        group_id: op.group_id,
        guest_id: op.guest_id,
        property_id: op.property_id,
        booked_on: op.occurred_on,
        arrival_on: stay.arrival_on,
        departure_on: stay.departure_on,
        rate_plan: op.rate_plan,
        status: "active",
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        revision: 1
      })

    case Repo.insert(changeset) do
      {:ok, group} ->
        insert_rooms(group, rooms)
        {:ok, group}

      {:error, _changeset} ->
        {:reject, "group_already_exists", %{}}
    end
  end

  defp insert_rooms(group, rooms) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, position} ->
        %{
          id: Ecto.UUID.generate(),
          group_id: group.id,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          position: position,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(Room, rows)
  end

  defp lodging_total(nights, rooms) do
    rooms
    |> Enum.map(&(&1.nightly_rate_cents * nights))
    |> Enum.sum()
  end

  defp deposit_due("advance_purchase", nights, rooms), do: lodging_total(nights, rooms)

  defp deposit_due("flexible", nights, rooms) do
    rooms
    |> Enum.map(fn room ->
      round_half_up_cents(room.nightly_rate_cents * nights, @flexible_deposit_percent)
    end)
    |> Enum.sum()
  end

  @doc false
  def round_half_up_cents(amount_cents, percent)
      when is_integer(amount_cents) and amount_cents >= 0 do
    div(amount_cents * percent + 50, 100)
  end

  # Payments

  defp validate_amount(amount) when is_integer(amount) and amount > 0, do: :ok
  defp validate_amount(_amount), do: {:reject, "invalid_amount", %{}}

  defp check_outstanding(group, amount_cents) do
    if amount_cents > group.deposit_due_cents - group.deposit_paid_cents do
      {:reject, "payment_exceeds_outstanding", %{}}
    else
      :ok
    end
  end

  defp apply_payment(group, amount_cents) do
    with {:ok, updated} <-
           update_group(group, %{deposit_paid_cents: group.deposit_paid_cents + amount_cents}),
         :ok <- Finance.adjust(cash_held_cents: amount_cents) do
      {:ok, updated}
    end
  end

  # Rescheduling

  defp validate_new_arrival(raw, occurred_on) do
    case parse_iso_date(raw) do
      {:ok, new_arrival_on} ->
        if Date.compare(new_arrival_on, occurred_on) == :gt do
          {:ok, new_arrival_on}
        else
          {:reject, "invalid_stay", %{}}
        end

      :error ->
        {:reject, "invalid_stay", %{}}
    end
  end

  defp apply_reschedule(group, new_arrival_on) do
    nights = Date.diff(group.departure_on, group.arrival_on)

    update_group(group, %{
      arrival_on: new_arrival_on,
      departure_on: Date.add(new_arrival_on, nights)
    })
  end

  # Cancelling

  defp settlement(group, occurred_on) do
    paid_cents = group.deposit_paid_cents

    if refundable?(group, occurred_on) do
      {:ok, paid_cents, 0}
    else
      {:ok, 0, paid_cents}
    end
  end

  defp refundable?(%Group{rate_plan: "flexible"} = group, occurred_on) do
    Date.diff(group.arrival_on, occurred_on) >= @refund_window_days
  end

  defp refundable?(_group, _occurred_on), do: false

  defp apply_cancellation(group, refunded_cents, retained_cents) do
    with {:ok, updated} <- update_group(group, %{status: "cancelled"}),
         :ok <-
           Finance.adjust(
             cash_held_cents: -group.deposit_paid_cents,
             cash_refunded_cents: refunded_cents,
             cash_retained_cents: retained_cents
           ) do
      {:ok, updated}
    end
  end

  # Persistence helpers

  defp update_group(%Group{} = group, changes) do
    group
    |> Ecto.Changeset.change(Map.put(changes, :revision, group.revision + 1))
    |> Repo.update()
  end

  # Results

  defp rejection(operation_id, code, group_id, extras \\ %{}) do
    %{operation_id: operation_id, status: "rejected", code: code}
    |> maybe_put_group_id(group_id)
    |> Map.merge(extras)
  end

  defp maybe_put_group_id(result, group_id) when is_binary(group_id) do
    Map.put(result, :group_id, group_id)
  end

  defp maybe_put_group_id(result, _group_id), do: result
end
