defmodule GroupStay.Groups do
  @moduledoc """
  The group reservation domain: reading groups, the cancellation policy
  attached to each group, and the finance totals derived from them.

  GroupStay owns the rooms represented by each group reservation, the deposit
  required for those rooms, the cash and hotel credit applied to that deposit,
  and the cancellation settlements that feed the finance totals.

  A group's policy version is fixed when the group is opened, derived from its
  original booking date: flexible groups booked before 2027-01-01 keep a
  14-day cancellation window, flexible groups booked on or after 2027-01-01
  use a 30-day window, and advance-purchase groups are non-refundable.

  The group's lodging, due, paid, and outstanding totals describe its active
  rooms only; every room exposes its own status, deposit, and the cash and
  credit currently funding it.
  """

  import Ecto.Query

  alias GroupStay.Allocations
  alias GroupStay.Credits
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  @policy_cutoff_date ~D[2027-01-01]
  @legacy_flexible_window_days 14
  @current_flexible_window_days 30

  @doc """
  Returns whether a group with the given partner identifier exists.
  """
  def group_exists?(group_id) when is_binary(group_id) do
    Repo.exists?(from g in Group, where: g.group_id == ^group_id)
  end

  @doc """
  Fetches a group by its partner identifier.
  """
  def fetch_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> :error
      %Group{} = group -> {:ok, group}
    end
  end

  @doc """
  The group's rooms, in their original order.
  """
  def rooms_for_group(%Group{} = group) do
    Repo.all(
      from r in Room,
        where: r.group_id == ^group.id,
        order_by: r.position
    )
  end

  @doc """
  The group's active rooms, in their original order.
  """
  def active_rooms(%Group{} = group) do
    Allocations.active_rooms(group)
  end

  @doc """
  Builds the JSON representation of a group, including its rooms in their
  original order and its deposit totals. The totals describe the active
  rooms only; every room exposes its status, its lodging and deposit
  amounts, and the cash and credit currently funding it.
  """
  def group_data(%Group{} = group) do
    rooms = rooms_for_group(group)
    funding = Allocations.room_funding(group)
    nights = Date.diff(group.departure_on, group.arrival_on)

    active_rooms = Enum.filter(rooms, &(&1.status == "active"))

    {lodging_total, deposit_due, cash_paid, credit_paid} =
      Enum.reduce(active_rooms, {0, 0, 0, 0}, fn room, {lodging, due, cash, credit} ->
        room_funding = Map.get(funding, room.id, %{cash: 0, credit: 0})
        room_lodging = room.nightly_rate_cents * nights

        {
          lodging + room_lodging,
          due + room.deposit_due_cents,
          cash + room_funding.cash,
          credit + room_funding.credit
        }
      end)

    deposit_paid = cash_paid + credit_paid

    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "revision" => group.revision,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "policy_version" => policy_version(group),
      "refundable_until" => iso_date(refundable_until(group)),
      "status" => group.status,
      "rooms" => Enum.map(rooms, &room_data(&1, funding, nights)),
      "lodging_total_cents" => lodging_total,
      "deposit_due_cents" => deposit_due,
      "deposit_paid_cents" => deposit_paid,
      "cash_paid_cents" => cash_paid,
      "credit_paid_cents" => credit_paid,
      "outstanding_deposit_cents" => deposit_due - deposit_paid
    }
  end

  defp room_data(%Room{} = room, funding, nights) do
    room_funding = Map.get(funding, room.id, %{cash: 0, credit: 0})

    %{
      "room_id" => room.room_id,
      "nightly_rate_cents" => room.nightly_rate_cents,
      "status" => room.status,
      "lodging_total_cents" => room.nightly_rate_cents * nights,
      "deposit_due_cents" => room.deposit_due_cents,
      "cash_paid_cents" => room_funding.cash,
      "credit_paid_cents" => room_funding.credit
    }
  end

  defp iso_date(nil), do: nil
  defp iso_date(%Date{} = date), do: Date.to_iso8601(date)

  @doc """
  The policy version fixed for the group when it was opened, derived from its
  original booking date.
  """
  def policy_version(%Group{rate_plan: "advance_purchase"}), do: "advance-nonrefundable"

  def policy_version(%Group{rate_plan: "flexible"} = group) do
    if legacy_flexible_policy?(group), do: "flex-14", else: "flex-30"
  end

  @doc """
  The last date on which cancelling the group is refundable: the arrival date
  minus the group's cancellation window. `nil` for advance purchase.
  """
  def refundable_until(%Group{rate_plan: "advance_purchase"}), do: nil

  def refundable_until(%Group{rate_plan: "flexible"} = group) do
    Date.add(group.arrival_on, -cancellation_window_days(group))
  end

  @doc """
  Whether a cancellation of the group on `date` is refundable. Cancelling on
  the `refundable_until` date itself is refundable.
  """
  def refundable?(%Group{} = group, %Date{} = date) do
    case refundable_until(group) do
      nil -> false
      refundable_until -> Date.compare(date, refundable_until) != :gt
    end
  end

  defp cancellation_window_days(%Group{} = group) do
    if legacy_flexible_policy?(group) do
      @legacy_flexible_window_days
    else
      @current_flexible_window_days
    end
  end

  defp legacy_flexible_policy?(%Group{booked_on: booked_on}) do
    Date.compare(booked_on, @policy_cutoff_date) == :lt
  end

  @doc """
  The deposit still to be paid on a group's active rooms. Once a group is
  cancelled its unpaid deposit is simply no longer due.
  """
  def outstanding_deposit_cents(%Group{status: "cancelled"}), do: 0

  def outstanding_deposit_cents(%Group{} = group) do
    group.deposit_due_cents - group.deposit_paid_cents
  end

  @doc """
  The finance totals over all groups: cash currently applied to active
  reservations, cash moved out of active reservations by cancellations, cash
  converted into hotel credit, cash removed by provider corrections, cash
  reversed by chargebacks, the credit liability, and the current credit
  shortfall, as of `as_of`. Unpaid deposit requirements are not cash and
  never appear here.
  """
  def ledger_totals(as_of \\ Date.utc_today()) do
    %{
      "cash_held_cents" => cash_held_cents(),
      "cash_refunded_cents" => sum_groups(:refunded_cents),
      "cash_retained_cents" => sum_groups(:retained_cents),
      "cash_converted_to_credit_cents" => sum_groups(:converted_to_credit_cents),
      "cash_reduced_cents" => sum_groups(:cash_reduced_cents),
      "cash_charged_back_cents" => sum_groups(:cash_charged_back_cents),
      "credit_liability_cents" => Credits.credit_liability_cents(as_of),
      "credit_shortfall_cents" => Credits.credit_shortfall_cents()
    }
  end

  defp cash_held_cents do
    Repo.one(
      from g in Group,
        where: g.status == "active",
        select: sum(g.deposit_paid_cents - g.credit_paid_cents)
    )
    |> Kernel.||(0)
  end

  defp sum_groups(field) do
    Repo.one(
      from g in Group,
        select: sum(field(g, ^field))
    )
    |> Kernel.||(0)
  end
end
