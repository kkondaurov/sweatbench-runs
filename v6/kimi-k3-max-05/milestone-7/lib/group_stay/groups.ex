defmodule GroupStay.Groups do
  @moduledoc """
  Lookup, persistence, and serialization helpers for group reservations.
  """

  import Ecto.Query

  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @flex_30_start ~D[2027-01-01]
  @cancellation_windows %{"flex-14" => 14, "flex-30" => 30}

  @doc """
  Returns the group with the given partner identifier, with rooms preloaded in
  their original order, or `nil` if there is none.
  """
  def get_group(group_id) when is_binary(group_id) do
    Repo.one(from g in Group, where: g.group_id == ^group_id, preload: [:rooms])
  end

  def get_group(_), do: nil

  @doc """
  The group's active rooms in their original order.
  """
  def active_rooms(%Group{} = group) do
    group = Repo.preload(group, :rooms, force: true)
    Enum.filter(group.rooms, &(&1.status == "active"))
  end

  @doc """
  The cancellation policy a group opened on the given booking date falls under.
  Advance-purchase groups are always non-refundable; flexible groups booked
  before 2027-01-01 keep the 14-day window, later bookings get 30 days.
  """
  def policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  def policy_version("flexible", booked_on) do
    if Date.compare(booked_on, @flex_30_start) == :lt, do: "flex-14", else: "flex-30"
  end

  @doc """
  The cancellation window in days for a group's fixed policy, or `nil` when
  the group is never refundable.
  """
  def cancellation_window(%Group{policy_version: policy_version}) do
    Map.get(@cancellation_windows, policy_version)
  end

  @doc """
  The last date on which cancellation is refundable: the arrival date minus
  the policy's window. `nil` for advance purchase.
  """
  def refundable_until(%Group{} = group) do
    case cancellation_window(group) do
      nil -> nil
      days -> Date.add(group.arrival_on, -days)
    end
  end

  @doc """
  Whether cancelling the group on the given date is refundable under the
  group's fixed policy. Cancellation on `refundable_until` itself is
  refundable.
  """
  def refundable?(%Group{} = group, %Date{} = on_date) do
    case cancellation_window(group) do
      nil -> false
      days -> Date.diff(group.arrival_on, on_date) >= days
    end
  end

  @doc """
  The group's totals over its active rooms: lodging, deposit due, paid (in
  cash, in credit, and overall), and the outstanding deposit.
  """
  def totals(%Group{} = group) do
    group = Repo.preload(group, :rooms, force: true)
    active = Enum.filter(group.rooms, &(&1.status == "active"))

    sums =
      Enum.reduce(active, {0, 0, 0, 0}, fn room, {lodging, due, cash, credit} ->
        {
          lodging + room.lodging_total_cents,
          due + room.deposit_due_cents,
          cash + room.cash_paid_cents,
          credit + room.credit_paid_cents
        }
      end)

    {lodging, due, cash, credit} = sums

    %{
      lodging_total_cents: lodging,
      deposit_due_cents: due,
      cash_paid_cents: cash,
      credit_paid_cents: credit,
      deposit_paid_cents: cash + credit,
      outstanding_deposit_cents: due - cash - credit
    }
  end

  @doc """
  The deposit still to pay. Cancellation forgives the unpaid remainder, so a
  cancelled group has no outstanding deposit.
  """
  def outstanding_deposit(%Group{} = group) do
    totals(group).outstanding_deposit_cents
  end

  @doc """
  Serializes a group for the partner API, including its rooms and totals.
  Group totals describe active rooms only.
  """
  def serialize(%Group{} = group) do
    group = Repo.preload(group, :rooms, force: true)
    totals = totals(group)

    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "revision" => group.revision,
      "booked_on" => Date.to_string(group.booked_on),
      "arrival_on" => Date.to_string(group.arrival_on),
      "departure_on" => Date.to_string(group.departure_on),
      "rate_plan" => group.rate_plan,
      "policy_version" => group.policy_version,
      "refundable_until" => serialize_date(refundable_until(group)),
      "status" => group.status,
      "rooms" => Enum.map(group.rooms, &serialize_room/1),
      "lodging_total_cents" => totals.lodging_total_cents,
      "deposit_due_cents" => totals.deposit_due_cents,
      "deposit_paid_cents" => totals.deposit_paid_cents,
      "cash_paid_cents" => totals.cash_paid_cents,
      "credit_paid_cents" => totals.credit_paid_cents,
      "outstanding_deposit_cents" => totals.outstanding_deposit_cents
    }
  end

  defp serialize_room(room) do
    %{
      "room_id" => room.room_id,
      "nightly_rate_cents" => room.nightly_rate_cents,
      "status" => room.status,
      "lodging_total_cents" => room.lodging_total_cents,
      "deposit_due_cents" => room.deposit_due_cents,
      "cash_paid_cents" => room.cash_paid_cents,
      "credit_paid_cents" => room.credit_paid_cents
    }
  end

  defp serialize_date(nil), do: nil
  defp serialize_date(%Date{} = date), do: Date.to_string(date)
end
