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
        %{
          group
          | rooms:
              Repo.all(
                from room in Room, where: room.group_id == ^group_id, order_by: room.position
              )
        }
    end
  end

  def get(_group_id), do: nil

  def active?(%Group{status: @active}), do: true
  def active?(_group), do: false

  def active_status, do: @active
  def cancelled_status, do: @cancelled

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
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: cash_paid(group),
      credit_paid_cents: group.credit_paid_cents || 0,
      outstanding_deposit_cents: max(group.deposit_due_cents - group.deposit_paid_cents, 0)
    }
  end

  def cash_paid(%Group{cash_paid_cents: cash_paid_cents, deposit_paid_cents: deposit_paid_cents}) do
    cash_paid_cents || deposit_paid_cents || 0
  end

  defp format_date(nil), do: nil
  defp format_date(%Date{} = date), do: Date.to_iso8601(date)
end
