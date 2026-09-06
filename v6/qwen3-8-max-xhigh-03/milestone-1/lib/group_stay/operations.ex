defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations submitted as batches.

  Each operation runs in its own transaction: an applied operation commits
  before the next operation starts, and a rejected operation rolls back so
  the database is left exactly as it was before the operation began.
  """

  import Ecto.Changeset, only: [change: 2]

  alias GroupStay.Repo
  alias GroupStay.Groups
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room

  @rate_plans ~w(flexible advance_purchase)
  @flexible_deposit_percent 20
  @refund_window_days 14

  @doc """
  Applies the operations in order and returns one result map per operation.
  """
  def apply_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_in_transaction/1)
  end

  defp apply_in_transaction(operation) do
    case Repo.transaction(fn ->
           case apply_operation(operation) do
             {:ok, result} -> result
             {:error, rejection} -> Repo.rollback(rejection)
           end
         end) do
      {:ok, result} -> result
      {:error, rejection} -> rejection
    end
  end

  defp apply_operation(operation) when not is_map(operation) do
    reject(nil, "invalid_operation")
  end

  defp apply_operation(operation) do
    raw_operation_id = Map.get(operation, "operation_id")

    with {:ok, operation_id} <- parse_identifier(raw_operation_id),
         {:ok, type} <- parse_identifier(Map.get(operation, "type")),
         {:ok, group_id} <- parse_identifier(Map.get(operation, "group_id")),
         {:ok, occurred_on} <- parse_iso_date(Map.get(operation, "occurred_on")),
         {:ok, handler} <- handler(type) do
      handler.(operation, %{
        operation_id: operation_id,
        group_id: group_id,
        occurred_on: occurred_on
      })
    else
      _ -> reject(raw_operation_id, "invalid_operation")
    end
  end

  defp handler("open_group"), do: {:ok, &open_group/2}
  defp handler("record_cash_payment"), do: {:ok, &record_cash_payment/2}
  defp handler("reschedule_group"), do: {:ok, &reschedule_group/2}
  defp handler("cancel_group"), do: {:ok, &cancel_group/2}
  defp handler(_), do: :error

  ## open_group

  defp open_group(operation, ctx) do
    with {:ok, guest_id} <- fetch_identifier(operation, "guest_id"),
         {:ok, property_id} <- fetch_identifier(operation, "property_id"),
         {:ok, arrival_raw} <- fetch_present(operation, "arrival_on"),
         {:ok, departure_raw} <- fetch_present(operation, "departure_on"),
         {:ok, rate_plan} <- fetch_identifier(operation, "rate_plan"),
         {:ok, rooms_raw} <- fetch_present(operation, "rooms"),
         :ok <- ensure_group_absent(ctx.group_id),
         {:ok, arrival_on, departure_on} <- parse_stay(arrival_raw, departure_raw),
         {:ok, rooms} <- parse_rooms(rooms_raw),
         :ok <- validate_rate_plan(rate_plan) do
      create_group(ctx, %{
        guest_id: guest_id,
        property_id: property_id,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        rooms: rooms
      })
    else
      {:error, code} -> reject(ctx.operation_id, code)
    end
  end

  defp ensure_group_absent(group_id) do
    if Repo.get(Group, group_id) do
      {:error, "group_already_exists"}
    else
      :ok
    end
  end

  defp parse_stay(arrival_raw, departure_raw) do
    with {:ok, arrival_on} <- parse_stay_date(arrival_raw),
         {:ok, departure_on} <- parse_stay_date(departure_raw),
         true <- Date.diff(departure_on, arrival_on) >= 1 do
      {:ok, arrival_on, departure_on}
    else
      _ -> {:error, "invalid_stay"}
    end
  end

  defp parse_stay_date(raw) do
    case parse_iso_date(raw) do
      {:ok, date} -> {:ok, date}
      :error -> {:error, "invalid_stay"}
    end
  end

  defp parse_rooms(rooms) when not is_list(rooms), do: {:error, "invalid_operation"}
  defp parse_rooms([]), do: {:error, "invalid_rooms"}

  defp parse_rooms(rooms) do
    parsed = Enum.map(rooms, &parse_room/1)

    if Enum.any?(parsed, &(&1 == :error)) do
      {:error, "invalid_rooms"}
    else
      room_ids = Enum.map(parsed, & &1.room_id)

      if length(Enum.uniq(room_ids)) != length(room_ids) do
        {:error, "invalid_rooms"}
      else
        {:ok, parsed}
      end
    end
  end

  defp parse_room(room) when is_map(room) do
    with room_id when is_binary(room_id) and room_id != "" <- Map.get(room, "room_id"),
         rate when is_integer(rate) and rate >= 0 <- Map.get(room, "nightly_rate_cents") do
      %{room_id: room_id, nightly_rate_cents: rate}
    else
      _ -> :error
    end
  end

  defp parse_room(_), do: :error

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp validate_rate_plan(_), do: {:error, "invalid_rate_plan"}

  defp create_group(ctx, attrs) do
    nights = Date.diff(attrs.departure_on, attrs.arrival_on)
    lodging_total_cents = lodging_total_cents(attrs.rooms, nights)
    deposit_due_cents = deposit_due_cents(attrs.rate_plan, attrs.rooms, nights)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    group = %Group{
      group_id: ctx.group_id,
      guest_id: attrs.guest_id,
      property_id: attrs.property_id,
      booked_on: ctx.occurred_on,
      arrival_on: attrs.arrival_on,
      departure_on: attrs.departure_on,
      rate_plan: attrs.rate_plan,
      revision: 1,
      lodging_total_cents: lodging_total_cents,
      deposit_due_cents: deposit_due_cents,
      inserted_at: now,
      updated_at: now
    }

    Repo.insert!(group)

    attrs.rooms
    |> Enum.with_index()
    |> Enum.each(fn {room, position} ->
      Repo.insert!(%Room{
        group_id: ctx.group_id,
        room_id: room.room_id,
        nightly_rate_cents: room.nightly_rate_cents,
        position: position,
        inserted_at: now,
        updated_at: now
      })
    end)

    {:ok,
     %{
       operation_id: ctx.operation_id,
       status: "applied",
       group_id: ctx.group_id,
       deposit_due_cents: deposit_due_cents,
       revision: 1
     }}
  end

  defp lodging_total_cents(rooms, nights) do
    rooms
    |> Enum.map(&(&1.nightly_rate_cents * nights))
    |> Enum.sum()
  end

  defp deposit_due_cents("flexible", rooms, nights) do
    rooms
    |> Enum.map(&percentage(&1.nightly_rate_cents * nights, @flexible_deposit_percent))
    |> Enum.sum()
  end

  defp deposit_due_cents("advance_purchase", rooms, nights) do
    lodging_total_cents(rooms, nights)
  end

  @doc """
  Rounds `amount * percent / 100` to the nearest cent; an exact half-cent
  rounds upward.
  """
  def percentage(amount, percent) when is_integer(amount) and amount >= 0 do
    div(2 * amount * percent + 100, 200)
  end

  ## record_cash_payment

  defp record_cash_payment(operation, ctx) do
    with {:ok, amount_raw} <- fetch_present(operation, "amount_cents"),
         {:ok, group} <- fetch_group(ctx.group_id),
         {:ok, group} <- check_revision(operation, group, ctx),
         :ok <- ensure_active(group),
         {:ok, amount_cents} <- parse_amount(amount_raw),
         :ok <- ensure_within_outstanding(group, amount_cents) do
      apply_payment(group, amount_cents, ctx)
    else
      {:error, %{} = rejection} -> {:error, rejection}
      {:error, code} -> reject(ctx.operation_id, code)
    end
  end

  defp parse_amount(amount) when is_integer(amount) and amount > 0, do: {:ok, amount}
  defp parse_amount(_), do: {:error, "invalid_amount"}

  defp ensure_within_outstanding(group, amount) do
    if amount <= Groups.outstanding_deposit_cents(group) do
      :ok
    else
      {:error, "payment_exceeds_outstanding"}
    end
  end

  defp apply_payment(group, amount_cents, ctx) do
    deposit_paid_cents = group.deposit_paid_cents + amount_cents
    revision = group.revision + 1

    group
    |> change(deposit_paid_cents: deposit_paid_cents, revision: revision)
    |> Repo.update!()

    {:ok,
     %{
       operation_id: ctx.operation_id,
       status: "applied",
       group_id: group.group_id,
       amount_cents: amount_cents,
       outstanding_deposit_cents: group.deposit_due_cents - deposit_paid_cents,
       revision: revision
     }}
  end

  ## reschedule_group

  defp reschedule_group(operation, ctx) do
    with {:ok, new_arrival_raw} <- fetch_present(operation, "new_arrival_on"),
         {:ok, group} <- fetch_group(ctx.group_id),
         {:ok, group} <- check_revision(operation, group, ctx),
         :ok <- ensure_active(group),
         {:ok, new_arrival_on} <- parse_stay_date(new_arrival_raw),
         :ok <- validate_new_arrival(new_arrival_on, ctx.occurred_on) do
      apply_reschedule(group, new_arrival_on, ctx)
    else
      {:error, %{} = rejection} -> {:error, rejection}
      {:error, code} -> reject(ctx.operation_id, code)
    end
  end

  defp validate_new_arrival(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt do
      :ok
    else
      {:error, "invalid_stay"}
    end
  end

  defp apply_reschedule(group, new_arrival_on, ctx) do
    shift_days = Date.diff(new_arrival_on, group.arrival_on)
    new_departure_on = Date.add(group.departure_on, shift_days)
    revision = group.revision + 1

    group
    |> change(arrival_on: new_arrival_on, departure_on: new_departure_on, revision: revision)
    |> Repo.update!()

    {:ok,
     %{
       operation_id: ctx.operation_id,
       status: "applied",
       group_id: group.group_id,
       new_arrival_on: new_arrival_on,
       new_departure_on: new_departure_on,
       revision: revision
     }}
  end

  ## cancel_group

  defp cancel_group(operation, ctx) do
    with {:ok, group} <- fetch_group(ctx.group_id),
         {:ok, group} <- check_revision(operation, group, ctx),
         :ok <- ensure_active(group) do
      apply_cancellation(group, ctx)
    else
      {:error, %{} = rejection} -> {:error, rejection}
      {:error, code} -> reject(ctx.operation_id, code)
    end
  end

  defp apply_cancellation(group, ctx) do
    refundable? =
      group.rate_plan == "flexible" and
        Date.diff(group.arrival_on, ctx.occurred_on) >= @refund_window_days

    refunded_cents = if refundable?, do: group.deposit_paid_cents, else: 0
    retained_cents = group.deposit_paid_cents - refunded_cents
    revision = group.revision + 1

    group
    |> change(
      status: "cancelled",
      refunded_cents: refunded_cents,
      retained_cents: retained_cents,
      revision: revision
    )
    |> Repo.update!()

    {:ok,
     %{
       operation_id: ctx.operation_id,
       status: "applied",
       group_id: group.group_id,
       refunded_cents: refunded_cents,
       retained_cents: retained_cents,
       revision: revision
     }}
  end

  ## shared helpers

  defp fetch_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, "group_not_found"}
      group -> {:ok, group}
    end
  end

  defp check_revision(operation, group, ctx) do
    case Map.get(operation, "expected_revision") do
      nil ->
        {:ok, group}

      expected ->
        if expected == group.revision do
          {:ok, group}
        else
          {:error,
           %{
             operation_id: ctx.operation_id,
             status: "rejected",
             code: "stale_revision",
             group_id: group.group_id,
             expected_revision: expected,
             actual_revision: group.revision
           }}
        end
    end
  end

  defp ensure_active(%Group{status: "active"}), do: :ok
  defp ensure_active(%Group{}), do: {:error, "group_not_active"}

  defp fetch_identifier(operation, key) do
    case parse_identifier(Map.get(operation, key)) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, "invalid_operation"}
    end
  end

  defp fetch_present(operation, key) do
    case Map.get(operation, key) do
      nil -> {:error, "invalid_operation"}
      value -> {:ok, value}
    end
  end

  defp parse_identifier(value) when is_binary(value) and value != "", do: {:ok, value}
  defp parse_identifier(_), do: :error

  defp parse_iso_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> :error
    end
  end

  defp parse_iso_date(_), do: :error

  defp reject(operation_id, code) do
    {:error, %{operation_id: operation_id, status: "rejected", code: code}}
  end
end
