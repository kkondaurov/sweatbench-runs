defmodule GroupStay.Groups do
  @moduledoc """
  The groups context: group reservations, their rooms, and the deposit state
  machine (open, funded, rescheduled, cancelled).
  """

  import Ecto.Query

  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @doc """
  Fetches a group by its partner-supplied identifier, with rooms in their
  original order. Returns `nil` when no such group exists.
  """
  def get_group(group_id) when is_binary(group_id) do
    Group
    |> where(group_id: ^group_id)
    |> preload(:rooms)
    |> Repo.one()
  end

  def get_group(_group_id), do: nil

  @doc """
  The number of nights in a stay.
  """
  def nights(%Group{} = group), do: Date.diff(group.departure_on, group.arrival_on)

  @doc """
  The deposit still owed by the group. Cancellation settles the requirement,
  so a cancelled group has no outstanding deposit.
  """
  def outstanding_deposit_cents(%Group{status: "cancelled"}), do: 0

  def outstanding_deposit_cents(%Group{} = group),
    do: group.deposit_due_cents - group.deposit_paid_cents

  @doc """
  Computes the lodging total and the deposit due for a stay.

  The lodging total is the sum of each room's nightly rate multiplied by the
  number of nights. Flexible rooms require 20% of their lodging as deposit;
  the percentage is calculated per room and rounded to the nearest cent with
  an exact half-cent rounding upward. Advance-purchase rooms require their
  full lodging amount.
  """
  def totals(rate_plan, rooms, nights) do
    lodging_total = Enum.sum(for room <- rooms, do: room.nightly_rate_cents * nights)

    deposit_due =
      Enum.sum(
        for room <- rooms, do: room_deposit_cents(rate_plan, room.nightly_rate_cents * nights)
      )

    %{lodging_total_cents: lodging_total, deposit_due_cents: deposit_due}
  end

  defp room_deposit_cents("flexible", lodging_cents), do: round_half_up(lodging_cents * 20, 100)
  defp room_deposit_cents("advance_purchase", lodging_cents), do: lodging_cents

  @doc """
  Rounds `numerator / denominator` to the nearest integer; an exact half
  rounds upward. Both arguments must be non-negative integers.
  """
  def round_half_up(numerator, denominator)
      when is_integer(numerator) and numerator >= 0 and is_integer(denominator) and
             denominator > 0 do
    div(2 * numerator + denominator, 2 * denominator)
  end

  @doc """
  The JSON representation of a group as returned by the read endpoint.
  """
  def group_payload(%Group{} = group) do
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
      rooms:
        Enum.map(group.rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: outstanding_deposit_cents(group)
    }
  end
end
