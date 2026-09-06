defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations in submission order and reports the outcome of
  each one.

  Each operation runs in its own transaction. A rejected operation rolls back
  everything it touched, leaves the database exactly as it was before the
  operation began, and processing continues with the next operation.
  """

  alias Ecto.Changeset
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  @rate_plans ["flexible", "advance_purchase"]
  @flexible_deposit_percent 20
  @refund_window_days 14

  @doc """
  Applies each operation map in order and returns one result map per
  operation, in the same order.
  """
  def submit(operations) when is_list(operations) do
    Enum.map(operations, &run/1)
  end

  defp run(operation) when is_map(operation) do
    outcome =
      Repo.transaction(fn ->
        case apply_operation(operation) do
          {:ok, result} -> result
          {:error, rejection} -> Repo.rollback(rejection)
        end
      end)

    case outcome do
      {:ok, result} -> result
      {:error, {code, details}} -> rejection(operation["operation_id"], code, details)
    end
  end

  defp run(_other), do: rejection(nil, :invalid_operation)

  defp apply_operation(%{"type" => "open_group"} = op), do: open_group(op)
  defp apply_operation(%{"type" => "record_cash_payment"} = op), do: record_cash_payment(op)
  defp apply_operation(%{"type" => "reschedule_group"} = op), do: reschedule_group(op)
  defp apply_operation(%{"type" => "cancel_group"} = op), do: cancel_group(op)
  defp apply_operation(_op), do: reject(:invalid_operation)

  ## open_group

  defp open_group(op) do
    with {:ok, occurred_on} <- parse_date(op["occurred_on"]),
         {:ok, group_id} <- fetch_identifier(op, "group_id"),
         {:ok, guest_id} <- fetch_identifier(op, "guest_id"),
         {:ok, property_id} <- fetch_identifier(op, "property_id"),
         {:ok, arrival_on} <- parse_date(op["arrival_on"]),
         {:ok, departure_on} <- parse_date(op["departure_on"]),
         {:ok, rate_plan} <- fetch_string(op, "rate_plan"),
         {:ok, rooms} <- fetch_rooms(op),
         :ok <- ensure_group_available(group_id),
         :ok <- validate_stay(arrival_on, departure_on),
         :ok <- validate_rooms(rooms),
         :ok <- validate_rate_plan(rate_plan) do
      create_group(op, %{
        occurred_on: occurred_on,
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        rooms: rooms
      })
    end
  end

  defp create_group(op, attrs) do
    nights = Date.diff(attrs.departure_on, attrs.arrival_on)

    rooms =
      Enum.map(attrs.rooms, fn %{"room_id" => room_id, "nightly_rate_cents" => rate} ->
        %Room{room_id: room_id, nightly_rate_cents: rate}
      end)

    lodging_total_cents =
      Enum.reduce(rooms, 0, fn room, total ->
        total + nights * room.nightly_rate_cents
      end)

    deposit_due_cents =
      Enum.reduce(rooms, 0, fn room, total ->
        total + room_deposit(attrs.rate_plan, nights * room.nightly_rate_cents)
      end)

    group =
      Repo.insert!(%Group{
        group_id: attrs.group_id,
        guest_id: attrs.guest_id,
        property_id: attrs.property_id,
        booked_on: attrs.occurred_on,
        arrival_on: attrs.arrival_on,
        departure_on: attrs.departure_on,
        rate_plan: attrs.rate_plan,
        status: "active",
        revision: 1,
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        rooms: rooms
      })

    {:ok,
     applied(op["operation_id"], %{
       group_id: group.group_id,
       deposit_due_cents: group.deposit_due_cents,
       revision: group.revision
     })}
  rescue
    error in Ecto.ConstraintError ->
      case error.constraint do
        "groups_group_id_index" -> reject(:group_already_exists)
        _other -> reraise error, __STACKTRACE__
      end
  end

  defp ensure_group_available(group_id) do
    if Repo.get_by(Group, group_id: group_id) do
      reject(:group_already_exists)
    else
      :ok
    end
  end

  defp validate_stay(arrival_on, departure_on) do
    if Date.diff(departure_on, arrival_on) >= 1 do
      :ok
    else
      reject(:invalid_stay)
    end
  end

  defp validate_rooms(rooms) do
    cond do
      rooms == [] -> reject(:invalid_rooms)
      Enum.any?(rooms, &invalid_room?/1) -> reject(:invalid_rooms)
      duplicate_room_ids?(rooms) -> reject(:invalid_rooms)
      true -> :ok
    end
  end

  defp invalid_room?(room) do
    case room do
      %{"room_id" => room_id, "nightly_rate_cents" => rate}
      when is_binary(room_id) and room_id != "" and is_integer(rate) and rate > 0 ->
        false

      _other ->
        true
    end
  end

  defp duplicate_room_ids?(rooms) do
    ids = Enum.map(rooms, & &1["room_id"])
    length(ids) != length(Enum.uniq(ids))
  end

  defp validate_rate_plan(rate_plan) do
    if rate_plan in @rate_plans do
      :ok
    else
      reject(:invalid_rate_plan)
    end
  end

  defp room_deposit("advance_purchase", lodging_cents), do: lodging_cents

  defp room_deposit("flexible", lodging_cents) do
    round_half_up(lodging_cents * @flexible_deposit_percent, 100)
  end

  defp round_half_up(numerator, denominator) do
    div(numerator + div(denominator, 2), denominator)
  end

  ## record_cash_payment

  defp record_cash_payment(op) do
    with {:ok, _occurred_on} <- parse_date(op["occurred_on"]),
         {:ok, group_id} <- fetch_identifier(op, "group_id"),
         {:ok, amount_cents} <- fetch_amount(op),
         {:ok, group} <- fetch_group(group_id),
         {:ok, group} <- revision_check(group, op),
         :ok <- active_check(group),
         :ok <- payment_check(group, amount_cents) do
      update_group(op, group, %{deposit_paid_cents: group.deposit_paid_cents + amount_cents}, fn
        updated ->
          %{
            group_id: updated.group_id,
            amount_cents: amount_cents,
            outstanding_deposit_cents: outstanding(updated),
            revision: updated.revision
          }
      end)
    end
  end

  defp fetch_amount(op) do
    case Map.fetch(op, "amount_cents") do
      {:ok, amount_cents} -> {:ok, amount_cents}
      :error -> reject(:invalid_operation)
    end
  end

  defp payment_check(group, amount_cents) do
    cond do
      not is_integer(amount_cents) or amount_cents <= 0 -> reject(:invalid_amount)
      amount_cents > outstanding(group) -> reject(:payment_exceeds_outstanding)
      true -> :ok
    end
  end

  ## reschedule_group

  defp reschedule_group(op) do
    with {:ok, occurred_on} <- parse_date(op["occurred_on"]),
         {:ok, group_id} <- fetch_identifier(op, "group_id"),
         {:ok, new_arrival_on} <- parse_date(op["new_arrival_on"]),
         {:ok, group} <- fetch_group(group_id),
         {:ok, group} <- revision_check(group, op),
         :ok <- active_check(group),
         :ok <- reschedule_check(occurred_on, new_arrival_on) do
      nights = Date.diff(group.departure_on, group.arrival_on)
      new_departure_on = Date.add(new_arrival_on, nights)

      update_group(
        op,
        group,
        %{arrival_on: new_arrival_on, departure_on: new_departure_on},
        fn updated ->
          %{
            group_id: updated.group_id,
            new_arrival_on: Date.to_iso8601(updated.arrival_on),
            new_departure_on: Date.to_iso8601(updated.departure_on),
            revision: updated.revision
          }
        end
      )
    end
  end

  defp reschedule_check(occurred_on, new_arrival_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt do
      :ok
    else
      reject(:invalid_stay)
    end
  end

  ## cancel_group

  defp cancel_group(op) do
    with {:ok, occurred_on} <- parse_date(op["occurred_on"]),
         {:ok, group_id} <- fetch_identifier(op, "group_id"),
         {:ok, group} <- fetch_group(group_id),
         {:ok, group} <- revision_check(group, op),
         :ok <- active_check(group) do
      {refunded_cents, retained_cents} = settlement(group, occurred_on)

      update_group(
        op,
        group,
        %{status: "cancelled", refunded_cents: refunded_cents, retained_cents: retained_cents},
        fn updated ->
          %{
            group_id: updated.group_id,
            refunded_cents: updated.refunded_cents,
            retained_cents: updated.retained_cents,
            revision: updated.revision
          }
        end
      )
    end
  end

  defp settlement(%Group{rate_plan: "flexible"} = group, occurred_on) do
    if Date.diff(group.arrival_on, occurred_on) >= @refund_window_days do
      {group.deposit_paid_cents, 0}
    else
      {0, group.deposit_paid_cents}
    end
  end

  defp settlement(%Group{} = group, _occurred_on), do: {0, group.deposit_paid_cents}

  ## shared helpers

  defp fetch_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> reject(:group_not_found)
      group -> {:ok, group}
    end
  end

  defp revision_check(%Group{} = group, op) do
    case Map.get(op, "expected_revision") do
      nil ->
        {:ok, group}

      expected_revision ->
        if expected_revision == group.revision do
          {:ok, group}
        else
          reject(:stale_revision, %{
            group_id: group.group_id,
            expected_revision: expected_revision,
            actual_revision: group.revision
          })
        end
    end
  end

  defp active_check(%Group{status: "active"}), do: :ok
  defp active_check(%Group{}), do: reject(:group_not_active)

  defp update_group(op, %Group{} = group, attrs, result) do
    group
    |> Changeset.change(attrs)
    |> Changeset.optimistic_lock(:revision)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        {:ok, applied(op["operation_id"], result.(updated))}

      {:error, _changeset} ->
        concurrent_modification(group.group_id)
    end
  end

  defp concurrent_modification(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        reject(:group_not_found)

      group ->
        reject(:stale_revision, %{
          group_id: group_id,
          expected_revision: nil,
          actual_revision: group.revision
        })
    end
  end

  defp outstanding(%Group{} = group) do
    group.deposit_due_cents - group.deposit_paid_cents
  end

  defp fetch_identifier(op, key) do
    case Map.get(op, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> reject(:invalid_operation)
    end
  end

  defp fetch_string(op, key) do
    case Map.get(op, key) do
      value when is_binary(value) -> {:ok, value}
      _other -> reject(:invalid_operation)
    end
  end

  defp fetch_rooms(op) do
    case Map.get(op, "rooms") do
      rooms when is_list(rooms) -> {:ok, rooms}
      _other -> reject(:invalid_operation)
    end
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> reject(:invalid_operation)
    end
  end

  defp parse_date(_other), do: reject(:invalid_operation)

  defp applied(operation_id, fields) do
    Map.merge(%{operation_id: operation_id, status: "applied"}, fields)
  end

  defp rejection(operation_id, code, details \\ %{}) do
    Map.merge(
      %{operation_id: operation_id, status: "rejected", code: Atom.to_string(code)},
      details
    )
  end

  defp reject(code, details \\ %{}), do: {:error, {code, details}}
end
