defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner batch operations to group reservations.

  Each operation runs inside its own transaction. A rejected operation
  rolls back every write it started, leaving the database exactly as it was
  before that operation began. The batch runner continues with the next
  operation after a rejection.

  Every applied operation addressed to an existing group increments that
  group's revision exactly once; rejections never increment it.
  """

  alias GroupStay.{Group, Groups, Payment, Repo, Room}

  import Ecto.Query, only: [from: 2]

  @rate_plans ["flexible", "advance_purchase"]
  @op_types ~w(open_group record_cash_payment reschedule_group cancel_group)

  @doc """
  Applies one operation and returns its client-facing, JSON-ready result.

  Applied results carry `"status" => "applied"` plus the fields of their
  operation type. Rejected results carry `"status" => "rejected"` and a
  stable `"code"`.
  """
  def apply_operation(%{} = op) do
    operation_id = Map.get(op, "operation_id")

    case Repo.transaction(fn -> run(op) end) do
      {:ok, {:apply, result}} -> result
      {:error, {:rejected, code, meta}} -> rejected_result(operation_id, code, meta)
    end
  end

  def apply_operation(_not_a_map) do
    rejected_result(nil, "invalid_operation", %{})
  end

  defp rejected_result(operation_id, code, meta) do
    base =
      if is_nil(operation_id) do
        %{"status" => "rejected", "code" => code}
      else
        %{"operation_id" => operation_id, "status" => "rejected", "code" => code}
      end

    Map.merge(base, meta)
  end

  defp reject(code), do: Repo.rollback({:rejected, code, %{}})
  defp reject(code, meta), do: Repo.rollback({:rejected, code, meta})

  defp run(op) do
    case common_fields(op) do
      {:ok, ctx} ->
        case ctx.type do
          "open_group" -> open_group(op, ctx)
          "record_cash_payment" -> record_cash_payment(op, ctx)
          "reschedule_group" -> reschedule_group(op, ctx)
          "cancel_group" -> cancel_group(op, ctx)
        end

      :error ->
        reject("invalid_operation")
    end
  end

  defp common_fields(op) do
    with {:ok, operation_id} <- required_string(op, "operation_id"),
         {:ok, type} <- known_type(op),
         {:ok, occurred_on} <- occurred_on(op, type) do
      {:ok, %{operation_id: operation_id, type: type, occurred_on: occurred_on}}
    else
      _ -> :error
    end
  end

  defp required_string(op, key) do
    case Map.get(op, key) do
      value when is_binary(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp known_type(op) do
    case Map.get(op, "type") do
      type when type in @op_types -> {:ok, type}
      _ -> :error
    end
  end

  defp occurred_on(op, type) when type != "record_cash_payment" do
    case Map.get(op, "occurred_on") do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _} -> :error
        end

      _ ->
        :error
    end
  end

  defp occurred_on(_op, "record_cash_payment"), do: {:ok, nil}

  ## open_group

  defp open_group(op, ctx) do
    with {:ok, group_id} <- required_string(op, "group_id"),
         {:ok, guest_id} <- required_string(op, "guest_id"),
         {:ok, property_id} <- required_string(op, "property_id"),
         :ok <- new_group(group_id),
         {:ok, arrival_on} <- stay_date(op, "arrival_on"),
         {:ok, departure_on} <- stay_date(op, "departure_on"),
         :ok <- one_or_more_nights(arrival_on, departure_on),
         {:ok, rate_plan} <- rate_plan(op),
         {:ok, rooms} <- rooms(op) do
      create_group(
        ctx,
        %{
          group_id: group_id,
          guest_id: guest_id,
          property_id: property_id,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: rate_plan,
          rooms: rooms
        }
      )
    else
      {:reject, code, meta} -> reject(code, meta)
      _ -> reject("invalid_operation")
    end
  end

  defp create_group(ctx, payload) do
    nights = Date.diff(payload.departure_on, payload.arrival_on)

    deposit_due =
      Enum.reduce(payload.rooms, 0, fn room, total ->
        Groups.room_deposit(room.nightly_rate_cents, payload.rate_plan, nights) + total
      end)

    group =
      try do
        Repo.insert!(%Group{
          group_id: payload.group_id,
          guest_id: payload.guest_id,
          property_id: payload.property_id,
          booked_on: ctx.occurred_on,
          arrival_on: payload.arrival_on,
          departure_on: payload.departure_on,
          rate_plan: payload.rate_plan,
          status: "active",
          revision: 1
        })
      rescue
        Ecto.ConstraintError ->
          reject("group_already_exists")
      end

    payload.rooms
    |> Enum.with_index()
    |> Enum.each(fn {room, index} ->
      Repo.insert!(%Room{
        group_id: group.id,
        room_id: room.room_id,
        nightly_rate_cents: room.nightly_rate_cents,
        position: index
      })
    end)

    {:apply,
     %{
       "operation_id" => ctx.operation_id,
       "status" => "applied",
       "group_id" => payload.group_id,
       "deposit_due_cents" => deposit_due,
       "revision" => 1
     }}
  end

  defp new_group(group_id) do
    if Repo.exists?(from(g in Group, where: g.group_id == ^group_id)) do
      {:reject, "group_already_exists", %{}}
    else
      :ok
    end
  end

  defp stay_date(op, key) do
    case Map.get(op, key) do
      nil ->
        {:reject, "invalid_operation", %{}}

      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _} -> {:reject, "invalid_stay", %{}}
        end

      _ ->
        {:reject, "invalid_stay", %{}}
    end
  end

  defp one_or_more_nights(arrival_on, departure_on) do
    if Date.diff(departure_on, arrival_on) >= 1 do
      :ok
    else
      {:reject, "invalid_stay", %{}}
    end
  end

  defp rate_plan(op) do
    case Map.get(op, "rate_plan") do
      nil ->
        {:reject, "invalid_operation", %{}}

      value when value in @rate_plans ->
        {:ok, value}

      _ ->
        {:reject, "invalid_rate_plan", %{}}
    end
  end

  defp rooms(op) do
    case Map.get(op, "rooms") do
      nil ->
        {:reject, "invalid_operation", %{}}

      rooms_list when is_list(rooms_list) ->
        validate_rooms(rooms_list)

      _ ->
        {:reject, "invalid_rooms", %{}}
    end
  end

  defp validate_rooms([]), do: {:reject, "invalid_rooms", %{}}

  defp validate_rooms(rooms_list) do
    rooms_list
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn room, {:ok, rooms, seen} ->
      case normalize_room(room, seen) do
        {:ok, normalized, seen} -> {:cont, {:ok, [normalized | rooms], seen}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, rooms, _seen} -> {:ok, Enum.reverse(rooms)}
      :error -> {:reject, "invalid_rooms", %{}}
    end
  end

  defp normalize_room(room, seen) when is_map(room) do
    room_id = Map.get(room, "room_id")
    rate = Map.get(room, "nightly_rate_cents")

    with true <- is_binary(room_id),
         true <- is_integer(rate) and rate > 0,
         false <- MapSet.member?(seen, room_id) do
      {:ok, %{room_id: room_id, nightly_rate_cents: rate}, MapSet.put(seen, room_id)}
    else
      _ -> :error
    end
  end

  defp normalize_room(_not_a_map, _seen), do: :error

  ## record_cash_payment

  defp record_cash_payment(op, ctx) do
    with {:ok, group_id} <- required_string(op, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- check_revision(op, group),
         :ok <- active(group),
         {:ok, amount} <- amount(op) do
      rooms = Repo.preload(group, :rooms).rooms
      outstanding = Groups.outstanding(group, rooms)

      if amount > outstanding do
        reject("payment_exceeds_outstanding")
      else
        Repo.insert!(%Payment{group_id: group.id, kind: "payment", amount_cents: amount})
        bump_revision(group)

        {:apply,
         %{
           "operation_id" => ctx.operation_id,
           "status" => "applied",
           "group_id" => group_id,
           "amount_cents" => amount,
           "outstanding_deposit_cents" => outstanding - amount,
           "revision" => group.revision + 1
         }}
      end
    else
      {:reject, code, meta} -> reject(code, meta)
      _ -> reject("invalid_operation")
    end
  end

  defp existing_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:reject, "group_not_found", %{}}
      group -> {:ok, group}
    end
  end

  defp active(%{status: "active"}), do: :ok
  defp active(_group), do: {:reject, "group_not_active", %{}}

  defp amount(op) do
    case Map.get(op, "amount_cents") do
      nil ->
        {:reject, "invalid_operation", %{}}

      value when is_integer(value) and value > 0 ->
        {:ok, value}

      _ ->
        {:reject, "invalid_amount", %{}}
    end
  end

  defp check_revision(op, group) do
    case Map.get(op, "expected_revision") do
      nil ->
        :ok

      expected when expected == group.revision ->
        :ok

      expected ->
        {:reject, "stale_revision",
         %{
           "group_id" => group.group_id,
           "expected_revision" => expected,
           "actual_revision" => group.revision
         }}
    end
  end

  defp bump_revision(group) do
    {_count, _} =
      Repo.update_all(from(g in Group, where: g.id == ^group.id), inc: [revision: 1])

    :ok
  end

  ## reschedule_group

  defp reschedule_group(op, ctx) do
    with {:ok, group_id} <- required_string(op, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- check_revision(op, group),
         :ok <- active(group),
         {:ok, new_arrival_on} <- new_arrival(op),
         :ok <- after_operation_date(new_arrival_on, ctx.occurred_on) do
      shift = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift)

      {_count, _} =
        Repo.update_all(
          from(g in Group, where: g.id == ^group.id),
          set: [arrival_on: new_arrival_on, departure_on: new_departure_on],
          inc: [revision: 1]
        )

      {:apply,
       %{
         "operation_id" => ctx.operation_id,
         "status" => "applied",
         "group_id" => group_id,
         "new_arrival_on" => Date.to_iso8601(new_arrival_on),
         "new_departure_on" => Date.to_iso8601(new_departure_on),
         "revision" => group.revision + 1
       }}
    else
      {:reject, code, meta} -> reject(code, meta)
      _ -> reject("invalid_operation")
    end
  end

  defp new_arrival(op) do
    case Map.get(op, "new_arrival_on") do
      nil ->
        {:reject, "invalid_operation", %{}}

      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _} -> {:reject, "invalid_stay", %{}}
        end

      _ ->
        {:reject, "invalid_stay", %{}}
    end
  end

  defp after_operation_date(date, operation_date) do
    if Date.compare(date, operation_date) == :gt do
      :ok
    else
      {:reject, "invalid_stay", %{}}
    end
  end

  ## cancel_group

  defp cancel_group(op, ctx) do
    with {:ok, group_id} <- required_string(op, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- check_revision(op, group),
         :ok <- active(group) do
      {refunded, retained} = settlement(group, ctx.occurred_on)

      if refunded > 0 do
        Repo.insert!(%Payment{group_id: group.id, kind: "refund", amount_cents: refunded})
      end

      if retained > 0 do
        Repo.insert!(%Payment{group_id: group.id, kind: "retained", amount_cents: retained})
      end

      {_count, _} =
        Repo.update_all(from(g in Group, where: g.id == ^group.id),
          set: [status: "cancelled"],
          inc: [revision: 1]
        )

      {:apply,
       %{
         "operation_id" => ctx.operation_id,
         "status" => "applied",
         "group_id" => group_id,
         "refunded_cents" => refunded,
         "retained_cents" => retained,
         "revision" => group.revision + 1
       }}
    else
      {:reject, code, meta} -> reject(code, meta)
      _ -> reject("invalid_operation")
    end
  end

  defp settlement(group, occurred_on) do
    paid = Groups.payments_total(group)

    refundable =
      group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred_on) >= 14

    if refundable, do: {paid, 0}, else: {0, paid}
  end
end
