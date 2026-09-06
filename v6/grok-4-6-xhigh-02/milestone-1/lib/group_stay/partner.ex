defmodule GroupStay.Partner do
  @moduledoc false

  alias GroupStay.Groups
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  @rate_plans ~w(flexible advance_purchase)
  @refund_lead_days 14

  def submit_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  defp apply_operation(operation) do
    case Repo.transaction(fn -> dispatch(operation) end) do
      {:ok, result} -> result
      {:error, result} when is_map(result) -> result
    end
  end

  defp dispatch(operation) when not is_map(operation) do
    reject(nil, "invalid_operation")
  end

  defp dispatch(operation) do
    case {field(operation, "operation_id"), normalize_type(field(operation, "type"))} do
      {operation_id, "open_group"} when is_binary(operation_id) ->
        open_group(operation, operation_id)

      {operation_id, "record_cash_payment"} when is_binary(operation_id) ->
        mutate_group(operation, operation_id, &record_cash_payment/4)

      {operation_id, "reschedule_group"} when is_binary(operation_id) ->
        mutate_group(operation, operation_id, &reschedule_group/4)

      {operation_id, "cancel_group"} when is_binary(operation_id) ->
        mutate_group(operation, operation_id, &cancel_group/4)

      {operation_id, _type} when is_binary(operation_id) ->
        reject(operation_id, "invalid_operation")

      _ ->
        reject(field(operation, "operation_id"), "invalid_operation")
    end
  end

  defp open_group(operation, operation_id) do
    with {:ok, occurred_on} <- require_date(operation, "occurred_on", operation_id),
         {:ok, group_id} <- require_id(operation, "group_id", operation_id),
         :ok <- ensure_new_group(group_id, operation_id),
         {:ok, guest_id} <- require_id(operation, "guest_id", operation_id),
         {:ok, property_id} <- require_id(operation, "property_id", operation_id),
         {:ok, arrival_on} <-
           require_present_date(operation, "arrival_on", operation_id, "invalid_stay"),
         {:ok, departure_on} <-
           require_present_date(operation, "departure_on", operation_id, "invalid_stay"),
         {:ok, rate_plan} <- require_rate_plan(operation, operation_id),
         {:ok, rooms} <- require_rooms(operation, operation_id) do
      nights = Groups.nights(arrival_on, departure_on)

      if nights < 1 do
        reject(operation_id, "invalid_stay")
      else
        insert_group(
          operation_id,
          %{
            group_id: group_id,
            guest_id: guest_id,
            property_id: property_id,
            booked_on: occurred_on,
            arrival_on: arrival_on,
            departure_on: departure_on,
            rate_plan: rate_plan,
            status: "active",
            revision: 1,
            lodging_total_cents: Groups.lodging_total_cents(rooms, nights),
            deposit_due_cents: Groups.deposit_due_cents(rooms, nights, rate_plan),
            deposit_paid_cents: 0,
            refunded_cents: 0,
            retained_cents: 0
          },
          rooms
        )
      end
    end
  end

  defp insert_group(operation_id, attrs, rooms) do
    room_structs =
      rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, position} ->
        %Room{
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          position: position
        }
      end)

    %Group{}
    |> Group.changeset(attrs)
    |> Ecto.Changeset.put_assoc(:rooms, room_structs)
    |> Repo.insert()
    |> case do
      {:ok, group} ->
        applied(operation_id, %{
          group_id: group.group_id,
          deposit_due_cents: group.deposit_due_cents,
          revision: group.revision
        })

      {:error, changeset} ->
        if unique_group_id_error?(changeset) do
          reject(operation_id, "group_already_exists")
        else
          reject(operation_id, "invalid_operation")
        end
    end
  end

  defp mutate_group(operation, operation_id, fun) do
    with {:ok, occurred_on} <- require_date(operation, "occurred_on", operation_id),
         {:ok, group_id} <- require_id(operation, "group_id", operation_id) do
      case Groups.get_by_group_id(group_id) do
        nil ->
          reject(operation_id, "group_not_found")

        group ->
          case check_revision(group, operation, operation_id) do
            :ok -> fun.(operation, operation_id, group, occurred_on)
            rejected -> rejected
          end
      end
    end
  end

  defp record_cash_payment(operation, operation_id, group, _occurred_on) do
    with :ok <- require_active(group, operation_id),
         {:ok, amount_cents} <- require_payment_amount(operation, operation_id) do
      outstanding = Groups.outstanding_deposit_cents(group)

      if amount_cents > outstanding do
        reject(operation_id, "payment_exceeds_outstanding")
      else
        paid = group.deposit_paid_cents + amount_cents
        group = persist_group!(group, %{deposit_paid_cents: paid, revision: group.revision + 1})

        applied(operation_id, %{
          group_id: group.group_id,
          amount_cents: amount_cents,
          outstanding_deposit_cents: Groups.outstanding_deposit_cents(group),
          revision: group.revision
        })
      end
    end
  end

  defp reschedule_group(operation, operation_id, group, occurred_on) do
    with :ok <- require_active(group, operation_id),
         {:ok, new_arrival_on} <-
           require_present_date(operation, "new_arrival_on", operation_id, "invalid_stay") do
      if Date.compare(new_arrival_on, occurred_on) != :gt do
        reject(operation_id, "invalid_stay")
      else
        shift_days = Date.diff(new_arrival_on, group.arrival_on)
        new_departure_on = Date.add(group.departure_on, shift_days)

        group =
          persist_group!(group, %{
            arrival_on: new_arrival_on,
            departure_on: new_departure_on,
            revision: group.revision + 1
          })

        applied(operation_id, %{
          group_id: group.group_id,
          new_arrival_on: group.arrival_on,
          new_departure_on: group.departure_on,
          revision: group.revision
        })
      end
    end
  end

  defp cancel_group(_operation, operation_id, group, occurred_on) do
    with :ok <- require_active(group, operation_id) do
      {refunded_cents, retained_cents} = settlement(group, occurred_on)

      group =
        persist_group!(group, %{
          status: "cancelled",
          refunded_cents: refunded_cents,
          retained_cents: retained_cents,
          revision: group.revision + 1
        })

      applied(operation_id, %{
        group_id: group.group_id,
        refunded_cents: refunded_cents,
        retained_cents: retained_cents,
        revision: group.revision
      })
    end
  end

  defp settlement(%Group{rate_plan: "advance_purchase"} = group, _occurred_on) do
    {0, group.deposit_paid_cents}
  end

  defp settlement(%Group{rate_plan: "flexible"} = group, occurred_on) do
    if Date.diff(group.arrival_on, occurred_on) >= @refund_lead_days do
      {group.deposit_paid_cents, 0}
    else
      {0, group.deposit_paid_cents}
    end
  end

  defp persist_group!(group, changes) do
    group
    |> Group.changeset(changes)
    |> Repo.update!()
  end

  defp ensure_new_group(group_id, operation_id) do
    if Groups.exists?(group_id) do
      reject(operation_id, "group_already_exists")
    else
      :ok
    end
  end

  defp normalize_type(type) when is_atom(type) and type != nil, do: Atom.to_string(type)
  defp normalize_type(type), do: type

  defp check_revision(group, operation, operation_id) do
    case field(operation, "expected_revision") do
      nil ->
        :ok

      expected when is_integer(expected) ->
        if expected == group.revision do
          :ok
        else
          rollback(%{
            operation_id: operation_id,
            status: "rejected",
            code: "stale_revision",
            group_id: group.group_id,
            expected_revision: expected,
            actual_revision: group.revision
          })
        end

      _ ->
        reject(operation_id, "invalid_operation")
    end
  end

  defp require_active(%Group{status: "active"}, _operation_id), do: :ok
  defp require_active(_group, operation_id), do: reject(operation_id, "group_not_active")

  defp require_id(operation, key, operation_id) do
    case field(operation, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> reject(operation_id, "invalid_operation")
    end
  end

  defp require_date(operation, key, operation_id) do
    case parse_date(field(operation, key)) do
      {:ok, date} -> {:ok, date}
      :error -> reject(operation_id, "invalid_operation")
    end
  end

  defp require_present_date(operation, key, operation_id, invalid_code) do
    case field(operation, key) do
      nil ->
        reject(operation_id, "invalid_operation")

      value ->
        case parse_date(value) do
          {:ok, date} -> {:ok, date}
          :error -> reject(operation_id, invalid_code)
        end
    end
  end

  defp require_rate_plan(operation, operation_id) do
    case normalize_type(field(operation, "rate_plan")) do
      plan when plan in @rate_plans -> {:ok, plan}
      plan when is_binary(plan) -> reject(operation_id, "invalid_rate_plan")
      _ -> reject(operation_id, "invalid_operation")
    end
  end

  defp require_rooms(operation, operation_id) do
    case field(operation, "rooms") do
      rooms when not is_list(rooms) or rooms == nil ->
        reject(operation_id, "invalid_operation")

      rooms ->
        parsed = Enum.map(rooms, &parse_room/1)

        cond do
          parsed == [] ->
            reject(operation_id, "invalid_rooms")

          Enum.any?(parsed, &(&1 == :invalid)) ->
            reject(operation_id, "invalid_rooms")

          true ->
            ids = Enum.map(parsed, & &1.room_id)

            if ids == Enum.uniq(ids) do
              {:ok, parsed}
            else
              reject(operation_id, "invalid_rooms")
            end
        end
    end
  end

  defp parse_room(room) when is_map(room) do
    room_id = field(room, "room_id")
    rate = field(room, "nightly_rate_cents")

    if is_binary(room_id) and room_id != "" and is_integer(rate) and rate >= 0 do
      %{room_id: room_id, nightly_rate_cents: rate}
    else
      :invalid
    end
  end

  defp parse_room(_), do: :invalid

  defp require_payment_amount(operation, operation_id) do
    case field(operation, "amount_cents") do
      amount when is_integer(amount) and amount > 0 ->
        {:ok, amount}

      amount when is_integer(amount) ->
        reject(operation_id, "invalid_amount")

      nil ->
        reject(operation_id, "invalid_operation")

      _ ->
        reject(operation_id, "invalid_amount")
    end
  end

  defp parse_date(%Date{} = date), do: {:ok, date}

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp parse_date(_), do: :error

  defp field(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, known_atom(key))
    end
  end

  defp known_atom("operation_id"), do: :operation_id
  defp known_atom("type"), do: :type
  defp known_atom("occurred_on"), do: :occurred_on
  defp known_atom("group_id"), do: :group_id
  defp known_atom("guest_id"), do: :guest_id
  defp known_atom("property_id"), do: :property_id
  defp known_atom("arrival_on"), do: :arrival_on
  defp known_atom("departure_on"), do: :departure_on
  defp known_atom("rate_plan"), do: :rate_plan
  defp known_atom("rooms"), do: :rooms
  defp known_atom("room_id"), do: :room_id
  defp known_atom("nightly_rate_cents"), do: :nightly_rate_cents
  defp known_atom("amount_cents"), do: :amount_cents
  defp known_atom("new_arrival_on"), do: :new_arrival_on
  defp known_atom("expected_revision"), do: :expected_revision
  defp known_atom(_), do: nil

  defp unique_group_id_error?(changeset) do
    Enum.any?(changeset.errors, fn
      {:group_id, {_, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end

  defp applied(operation_id, fields) do
    Map.merge(%{operation_id: operation_id, status: "applied"}, fields)
  end

  defp reject(operation_id, code) do
    result =
      if is_binary(operation_id) do
        %{operation_id: operation_id, status: "rejected", code: code}
      else
        %{status: "rejected", code: code}
      end

    rollback(result)
  end

  defp rollback(result) do
    Repo.rollback(result)
  end
end
