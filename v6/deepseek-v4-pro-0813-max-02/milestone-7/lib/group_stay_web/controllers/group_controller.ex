defmodule GroupStayWeb.GroupController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups
  alias GroupStay.Policy
  alias GroupStay.RoomAccounting

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"group_id" => group_id}) do
    case Groups.fetch(group_id) do
      {:ok, %{group: group, rooms: rooms, allocations: allocations}} ->
        json(conn, %{data: serialize_group(group, rooms, allocations)})

      :not_found ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "group_not_found"}})
    end
  end

  defp serialize_group(group, rooms, allocations) do
    policy_version = Policy.for_group(group)

    held_by_room =
      allocations
      |> Enum.group_by(& &1.room_id)

    active_rooms = Enum.filter(rooms, &(&1.status == "active"))

    lodging_total_cents =
      Enum.reduce(active_rooms, 0, &(RoomAccounting.room_lodging_cents(group, &1) + &2))

    deposit_due_cents = Enum.reduce(active_rooms, 0, &(&1.deposit_due_cents + &2))

    cash_paid_cents =
      paid_for_kind(active_rooms, held_by_room, "cash")

    credit_paid_cents =
      paid_for_kind(active_rooms, held_by_room, "credit")

    deposit_paid_cents = cash_paid_cents + credit_paid_cents

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
      policy_version: policy_version,
      refundable_until: serialize_refundable_until(policy_version, group.arrival_on),
      rooms: Enum.map(rooms, &serialize_room(&1, held_by_room)),
      lodging_total_cents: lodging_total_cents,
      deposit_due_cents: deposit_due_cents,
      deposit_paid_cents: deposit_paid_cents,
      cash_paid_cents: cash_paid_cents,
      credit_paid_cents: credit_paid_cents,
      outstanding_deposit_cents: deposit_due_cents - deposit_paid_cents
    }
  end

  defp paid_for_kind(rooms, held_by_room, kind) do
    Enum.reduce(rooms, 0, fn room, total ->
      total + held_for_kind(Map.get(held_by_room, room.id, []), kind)
    end)
  end

  defp held_for_kind(rows, kind) do
    rows
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.reduce(0, &(&1.amount_cents + &2))
  end

  defp serialize_room(room, held_by_room) do
    active = room.status == "active"

    %{
      room_id: room.room_id,
      nightly_rate_cents: room.nightly_rate_cents,
      status: if(active, do: "active", else: "cancelled"),
      deposit_due_cents: if(active, do: room.deposit_due_cents, else: 0),
      cash_paid_cents:
        if(active, do: held_for_kind(Map.get(held_by_room, room.id, []), "cash"), else: 0),
      credit_paid_cents:
        if(active, do: held_for_kind(Map.get(held_by_room, room.id, []), "credit"), else: 0)
    }
  end

  defp serialize_refundable_until(policy_version, arrival_on) do
    case Policy.refundable_until(policy_version, arrival_on) do
      nil -> nil
      date -> Date.to_iso8601(date)
    end
  end
end
