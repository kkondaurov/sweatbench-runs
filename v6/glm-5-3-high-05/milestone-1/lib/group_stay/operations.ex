defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations one at a time, in order.

  Each operation runs inside its own transaction. A rejected operation is
  rolled back completely, leaving the database exactly as it was before that
  operation began, and the caller continues with the next operation.

  Result values are plain maps so the HTTP layer can render them directly:

      {:ok, %{...applied fields...}}
      {:error, %{"code" => "...", ...extra rejection fields...}}

  Ordering rules shared by every operation addressed to an existing group:

    1. group existence is resolved first (`group_not_found`);
    2. a stale `expected_revision` is rejected before any other domain rule;
    3. only then are the operation's own domain rules evaluated.
  """

  alias GroupStay.Groups
  alias GroupStay.Groups.Group
  alias GroupStay.Ledger
  alias GroupStay.Repo

  @known_types ["open_group", "record_cash_payment", "reschedule_group", "cancel_group"]
  @refundable_window_days 14

  @doc """
  Applies a single operation map, returning `{:ok, extra}` on success and
  `{:error, error}` on rejection.
  """
  def apply(op) when is_map(op) do
    case Repo.transaction(fn -> run(op) end) do
      {:ok, result} -> {:ok, result}
      {:error, error} -> {:error, error}
    end
  end

  def apply(_op) do
    {:error, %{"code" => "invalid_operation"}}
  end

  defp run(op) do
    case run_operation(op) do
      {:ok, result} -> result
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp run_operation(%{"type" => type} = op) when type in @known_types do
    with {:ok, occurred_on} <- common_fields(op) do
      run_typed(type, op, occurred_on)
    end
  end

  defp run_operation(_op) do
    {:error, %{"code" => "invalid_operation"}}
  end

  defp run_typed("open_group", op, occurred_on), do: open_group(op, occurred_on)
  defp run_typed("record_cash_payment", op, occurred_on), do: record_cash_payment(op, occurred_on)
  defp run_typed("reschedule_group", op, occurred_on), do: reschedule_group(op, occurred_on)
  defp run_typed("cancel_group", op, occurred_on), do: cancel_group(op, occurred_on)

  ## open_group

  defp open_group(op, occurred_on) do
    with {:ok, group_id} <- fetch_id(op, "group_id"),
         {:ok, guest_id} <- fetch_id(op, "guest_id"),
         {:ok, property_id} <- fetch_id(op, "property_id"),
         :ok <- check_group_absent(group_id),
         {:ok, rate_plan} <- fetch_rate_plan(op),
         {:ok, arrival_on} <- fetch_date(op, "arrival_on", "invalid_stay"),
         {:ok, departure_on} <- fetch_date(op, "departure_on", "invalid_stay"),
         :ok <- check_stay(arrival_on, departure_on),
         {:ok, rooms} <- fetch_rooms(op) do
      group =
        Repo.insert!(%Group{
          group_id: group_id,
          guest_id: guest_id,
          property_id: property_id,
          arrival_on: arrival_on,
          departure_on: departure_on,
          booked_on: occurred_on,
          rate_plan: rate_plan,
          status: "active",
          revision: 1,
          rooms: rooms
        })

      deposit_due = Groups.deposit_due_cents(%{group | rooms: rooms})

      {:ok,
       %{
         "group_id" => group_id,
         "deposit_due_cents" => deposit_due,
         "revision" => group.revision
       }}
    end
  end

  defp check_group_absent(group_id) do
    if Repo.get_by(Group, group_id: group_id) do
      {:error, %{"code" => "group_already_exists"}}
    else
      :ok
    end
  end

  defp fetch_rate_plan(op) do
    case op["rate_plan"] do
      rate_plan when rate_plan in ["flexible", "advance_purchase"] -> {:ok, rate_plan}
      _ -> {:error, %{"code" => "invalid_rate_plan"}}
    end
  end

  defp check_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt do
      :ok
    else
      {:error, %{"code" => "invalid_stay"}}
    end
  end

  defp fetch_rooms(op) do
    rooms = op["rooms"]

    cond do
      not is_list(rooms) or rooms == [] ->
        {:error, %{"code" => "invalid_rooms"}}

      true ->
        rooms
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {room, position}, {:ok, acc} ->
          case parse_room(room, position) do
            {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, parsed} -> check_unique_room_ids(Enum.reverse(parsed))
          {:error, _} = error -> error
        end
    end
  end

  defp parse_room(room, position) do
    case room do
      %{"room_id" => room_id, "nightly_rate_cents" => rate}
      when is_binary(room_id) and room_id != "" and is_integer(rate) and rate > 0 ->
        {:ok,
         %GroupStay.Groups.Room{
           room_id: room_id,
           nightly_rate_cents: rate,
           position: position
         }}

      _ ->
        {:error, %{"code" => "invalid_rooms"}}
    end
  end

  defp check_unique_room_ids(rooms) do
    room_ids = Enum.map(rooms, & &1.room_id)

    if length(room_ids) == length(Enum.uniq(room_ids)) do
      {:ok, rooms}
    else
      {:error, %{"code" => "invalid_rooms"}}
    end
  end

  ## record_cash_payment

  defp record_cash_payment(op, occurred_on) do
    with {:ok, group_id} <- fetch_id(op, "group_id"),
         {:ok, group} <- fetch_group(group_id),
         :ok <- check_revision(op, group),
         :ok <- check_active(group),
         {:ok, amount_cents} <- fetch_amount(op) do
      outstanding = Groups.outstanding_deposit_cents(group)

      if amount_cents > outstanding do
        {:error, %{"code" => "payment_exceeds_outstanding"}}
      else
        Ledger.record_payment!(group.id, amount_cents, occurred_on)
        revision = bump_revision!(group)

        {:ok,
         %{
           "group_id" => group_id,
           "amount_cents" => amount_cents,
           "outstanding_deposit_cents" => outstanding - amount_cents,
           "revision" => revision
         }}
      end
    end
  end

  defp fetch_amount(op) do
    case op["amount_cents"] do
      amount when is_integer(amount) and amount > 0 -> {:ok, amount}
      _ -> {:error, %{"code" => "invalid_amount"}}
    end
  end

  ## reschedule_group

  defp reschedule_group(op, occurred_on) do
    with {:ok, group_id} <- fetch_id(op, "group_id"),
         {:ok, group} <- fetch_group(group_id),
         :ok <- check_revision(op, group),
         :ok <- check_active(group),
         {:ok, new_arrival_on} <- fetch_date(op, "new_arrival_on", "invalid_stay"),
         :ok <- check_after(new_arrival_on, occurred_on) do
      nights = Groups.nights(group)
      new_departure_on = Date.add(new_arrival_on, nights)

      group
      |> Ecto.Changeset.change(
        arrival_on: new_arrival_on,
        departure_on: new_departure_on
      )
      |> Repo.update!()

      revision = bump_revision!(group)

      {:ok,
       %{
         "group_id" => group_id,
         "new_arrival_on" => Date.to_iso8601(new_arrival_on),
         "new_departure_on" => Date.to_iso8601(new_departure_on),
         "revision" => revision
       }}
    end
  end

  defp check_after(date, reference_date) do
    if Date.compare(date, reference_date) == :gt do
      :ok
    else
      {:error, %{"code" => "invalid_stay"}}
    end
  end

  ## cancel_group

  defp cancel_group(op, occurred_on) do
    with {:ok, group_id} <- fetch_id(op, "group_id"),
         {:ok, group} <- fetch_group(group_id),
         :ok <- check_revision(op, group),
         :ok <- check_active(group) do
      paid_cents = Groups.deposit_paid_cents(group)
      {refunded_cents, retained_cents} = settle_cancellation(group, occurred_on, paid_cents)

      if refunded_cents > 0, do: Ledger.record_refund!(group.id, refunded_cents, occurred_on)
      if retained_cents > 0, do: Ledger.record_retention!(group.id, retained_cents, occurred_on)

      group
      |> Ecto.Changeset.change(status: "cancelled")
      |> Repo.update!()

      revision = bump_revision!(group)

      {:ok,
       %{
         "group_id" => group_id,
         "refunded_cents" => refunded_cents,
         "retained_cents" => retained_cents,
         "revision" => revision
       }}
    end
  end

  defp settle_cancellation(%Group{rate_plan: "flexible"} = group, occurred_on, paid_cents) do
    days_before_arrival = Date.diff(group.arrival_on, occurred_on)

    if days_before_arrival >= @refundable_window_days do
      {paid_cents, 0}
    else
      {0, paid_cents}
    end
  end

  defp settle_cancellation(%Group{rate_plan: "advance_purchase"}, _occurred_on, paid_cents) do
    {0, paid_cents}
  end

  ## shared helpers

  defp common_fields(op) do
    with :ok <- check_present(op, "operation_id"),
         {:ok, occurred_on} <- fetch_date(op, "occurred_on", "invalid_operation") do
      {:ok, occurred_on}
    end
  end

  defp check_present(op, key) do
    if Map.has_key?(op, key) and op[key] != nil do
      :ok
    else
      {:error, %{"code" => "invalid_operation"}}
    end
  end

  defp fetch_id(op, key) do
    case op[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, %{"code" => "invalid_operation"}}
    end
  end

  defp fetch_date(op, key, error_code) do
    case op[key] do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _} -> {:error, %{"code" => error_code}}
        end

      _ ->
        {:error, %{"code" => error_code}}
    end
  end

  defp fetch_group(group_id) do
    case Groups.get_group(group_id) do
      nil -> {:error, %{"code" => "group_not_found"}}
      group -> {:ok, group}
    end
  end

  defp check_revision(op, %Group{} = group) do
    case Map.get(op, "expected_revision") do
      nil ->
        :ok

      expected_revision ->
        if expected_revision == group.revision do
          :ok
        else
          {:error,
           %{
             "code" => "stale_revision",
             "group_id" => group.group_id,
             "expected_revision" => expected_revision,
             "actual_revision" => group.revision
           }}
        end
    end
  end

  defp check_active(%Group{status: "active"}), do: :ok

  defp check_active(%Group{}), do: {:error, %{"code" => "group_not_active"}}

  defp bump_revision!(%Group{} = group) do
    next = group.revision + 1
    group |> Ecto.Changeset.change(revision: next) |> Repo.update!()
    next
  end
end
