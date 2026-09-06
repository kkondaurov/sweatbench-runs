defmodule GroupStay.Operations.OpenGroup do
  @moduledoc """
  Opens a group reservation from an `open_group` operation.

  A stay spans at least one night and has at least one room. Room identifiers
  are unique within the group. Each room's lodging amount is its nightly rate
  multiplied by the number of nights; a flexible room requires a 20% deposit
  rounded per room to the nearest cent (an exact half-cent rounds up), while an
  advance-purchase room requires its full lodging amount as the deposit.
  """

  alias GroupStay.Groups
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Operations
  alias GroupStay.Policy
  alias GroupStay.Repo

  @rate_plans ["flexible", "advance_purchase"]

  @required_fields [
    :operation_id,
    :group_id,
    :occurred_on,
    :guest_id,
    :property_id,
    :arrival_on,
    :departure_on,
    :rate_plan,
    :rooms
  ]

  @spec apply(map()) :: map()
  def apply(operation) do
    with {:ok, fields} <- Operations.require_fields(operation, @required_fields),
         :ok <- validate_identifiers(fields),
         {:ok, booked_on} <- Operations.parse_date(fields.occurred_on),
         {:ok, stay} <- validate_stay(fields),
         :ok <- validate_rate_plan(fields.rate_plan),
         {:ok, rooms} <- validate_rooms(fields.rooms),
         :ok <- assert_group_available(fields.group_id) do
      insert_group(operation, fields, rooms, booked_on, stay)
    else
      :invalid_operation -> Operations.rejected(operation, "invalid_operation")
      {:invalid, code} -> Operations.rejected(operation, code)
      _ -> Operations.rejected(operation, "invalid_operation")
    end
  end

  defp validate_identifiers(%{group_id: group_id, guest_id: guest_id, property_id: property_id}) do
    if is_binary(group_id) and is_binary(guest_id) and is_binary(property_id) do
      :ok
    else
      :invalid_operation
    end
  end

  defp validate_stay(%{arrival_on: arrival_on, departure_on: departure_on}) do
    with {:ok, arrival} <- Operations.parse_date(arrival_on),
         {:ok, departure} <- Operations.parse_date(departure_on),
         true <- Date.compare(arrival, departure) == :lt do
      {:ok, {arrival, departure}}
    else
      _ -> {:invalid, "invalid_stay"}
    end
  end

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp validate_rate_plan(_rate_plan), do: {:invalid, "invalid_rate_plan"}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    if Enum.all?(rooms, &valid_room?/1) and unique_room_ids?(rooms) do
      {:ok, rooms}
    else
      {:invalid, "invalid_rooms"}
    end
  end

  defp validate_rooms(_rooms), do: {:invalid, "invalid_rooms"}

  defp valid_room?(%{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents})
       when is_binary(room_id) do
    is_integer(nightly_rate_cents) and nightly_rate_cents > 0
  end

  defp valid_room?(_room), do: false

  defp unique_room_ids?(rooms) do
    ids = Enum.map(rooms, & &1["room_id"])
    length(ids) == MapSet.size(MapSet.new(ids))
  end

  defp assert_group_available(group_id) do
    if Groups.exists?(group_id) do
      {:invalid, "group_already_exists"}
    else
      :ok
    end
  end

  defp insert_group(operation, fields, rooms, booked_on, {arrival, departure}) do
    nights = Date.diff(departure, arrival)
    policy_version = Policy.policy_version(fields.rate_plan, booked_on)

    lodging_total_cents =
      Enum.reduce(rooms, 0, fn room, total ->
        total + nights * room["nightly_rate_cents"]
      end)

    deposit_due_cents =
      Enum.reduce(rooms, 0, fn room, total ->
        amount = nights * room["nightly_rate_cents"]
        total + deposit_for_room(amount, fields.rate_plan)
      end)

    {:ok, _group} =
      Repo.transaction(fn ->
        {:ok, group} =
          Repo.insert(%Group{
            group_id: fields.group_id,
            guest_id: fields.guest_id,
            property_id: fields.property_id,
            booked_on: booked_on,
            arrival_on: arrival,
            departure_on: departure,
            rate_plan: fields.rate_plan,
            status: "active",
            revision: 1,
            policy_version: policy_version,
            lodging_total_cents: lodging_total_cents,
            deposit_due_cents: deposit_due_cents,
            deposit_paid_cents: 0,
            cash_paid_cents: 0,
            credit_paid_cents: 0
          })

        rooms
        |> Enum.with_index()
        |> Enum.each(fn {%{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents},
                         position} ->
          {:ok, _room} =
            Repo.insert(%Room{
              room_id: room_id,
              nightly_rate_cents: nightly_rate_cents,
              position: position,
              group_id: group.id
            })
        end)

        group
      end)

    Operations.applied(operation,
      group_id: fields.group_id,
      deposit_due_cents: deposit_due_cents,
      revision: 1
    )
  end

  defp deposit_for_room(amount, "flexible") do
    # 20% of the lodging amount, rounded to the nearest cent, half up.
    div(amount * 2 + 5, 10)
  end

  defp deposit_for_room(amount, "advance_purchase"), do: amount
end
