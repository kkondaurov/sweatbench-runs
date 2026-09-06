defmodule GroupStay.Groups do
  @moduledoc "Persistence and read operations for group reservations."

  import Ecto.Query

  alias GroupStay.Groups.{Group, Room}
  alias GroupStay.Repo

  @active "active"
  @cancelled "cancelled"
  @policy_cutover ~D[2027-01-01]
  @flexible "flexible"
  @advance_purchase "advance_purchase"

  def get(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil ->
        nil

      group ->
        %{group | rooms: rooms_for(group_id)}
    end
  end

  def get(_group_id), do: nil

  def active?(%Group{status: @active}), do: true
  def active?(_group), do: false

  def active_status, do: @active
  def cancelled_status, do: @cancelled

  def rooms_for(group_id) do
    Repo.all(from room in Room, where: room.group_id == ^group_id, order_by: room.position)
  end

  def active_rooms(%Group{rooms: rooms}) when is_list(rooms),
    do: Enum.filter(rooms, &active_room?/1)

  def active_rooms(%Group{group_id: group_id}),
    do: rooms_for(group_id) |> Enum.filter(&active_room?/1)

  def active_room?(%Room{status: @active}), do: true
  def active_room?(_room), do: false

  def room_deposit_paid(%Room{} = room),
    do: (room.cash_paid_cents || 0) + (room.credit_paid_cents || 0)

  def room_outstanding(%Room{} = room),
    do: max((room.deposit_due_cents || 0) - room_deposit_paid(room), 0)

  def totals(%Group{} = group) do
    rooms = if is_list(group.rooms), do: group.rooms, else: rooms_for(group.group_id)
    active_rooms = Enum.filter(rooms, &active_room?/1)
    lodging_total_cents = Enum.sum(Enum.map(active_rooms, &(&1.lodging_total_cents || 0)))
    deposit_due_cents = Enum.sum(Enum.map(active_rooms, &(&1.deposit_due_cents || 0)))
    cash_paid_cents = Enum.sum(Enum.map(active_rooms, &(&1.cash_paid_cents || 0)))
    credit_paid_cents = Enum.sum(Enum.map(active_rooms, &(&1.credit_paid_cents || 0)))

    %{
      lodging_total_cents: lodging_total_cents,
      deposit_due_cents: deposit_due_cents,
      deposit_paid_cents: cash_paid_cents + credit_paid_cents,
      cash_paid_cents: cash_paid_cents,
      credit_paid_cents: credit_paid_cents,
      outstanding_deposit_cents: max(deposit_due_cents - cash_paid_cents - credit_paid_cents, 0)
    }
  end

  def policy_version(%Group{policy_version: policy_version})
      when policy_version in ["flex-14", "flex-30", "advance-nonrefundable"],
      do: policy_version

  def policy_version(%Group{rate_plan: @advance_purchase}), do: "advance-nonrefundable"

  def policy_version(%Group{rate_plan: @flexible, booked_on: booked_on}) do
    if Date.compare(booked_on, @policy_cutover) == :lt, do: "flex-14", else: "flex-30"
  end

  def cancellation_window(%Group{} = group) do
    case policy_version(group) do
      "flex-14" -> 14
      "flex-30" -> 30
      "advance-nonrefundable" -> nil
    end
  end

  def refundable_until(%Group{} = group) do
    case cancellation_window(group) do
      nil -> nil
      window -> Date.add(group.arrival_on, -window)
    end
  end

  def serialize(%Group{} = group) do
    totals = totals(group)

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: policy_version(group),
      refundable_until: format_date(refundable_until(group)),
      status: group.status,
      revision: group.revision,
      rooms:
        Enum.map(group.rooms || [], fn room ->
          %{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            lodging_total_cents: room.lodging_total_cents,
            status: room.status || @active,
            deposit_due_cents: room.deposit_due_cents || 0,
            cash_paid_cents: room.cash_paid_cents || 0,
            credit_paid_cents: room.credit_paid_cents || 0
          }
        end),
      lodging_total_cents: totals.lodging_total_cents,
      deposit_due_cents: totals.deposit_due_cents,
      deposit_paid_cents: totals.deposit_paid_cents,
      cash_paid_cents: totals.cash_paid_cents,
      credit_paid_cents: totals.credit_paid_cents,
      outstanding_deposit_cents: totals.outstanding_deposit_cents
    }
  end

  def cash_paid(%Group{} = group) do
    if is_list(group.rooms) do
      totals(group).cash_paid_cents
    else
      group.cash_paid_cents || group.deposit_paid_cents || 0
    end
  end

  defp format_date(nil), do: nil
  defp format_date(%Date{} = date), do: Date.to_iso8601(date)
end
