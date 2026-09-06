defmodule GroupStay.Groups do
  @moduledoc """
  Read access to group reservations and the finance ledger.
  """

  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Credit
  alias GroupStay.Groups.Group

  @policy_cutoff ~D[2027-01-01]
  @flex_windows %{"flex-14" => 14, "flex-30" => 30}

  @doc """
  Returns the group with its rooms in their original order, or nil.
  """
  def get_group(group_id) when is_binary(group_id) do
    Group
    |> Repo.get(group_id)
    |> Repo.preload(rooms: from(r in GroupStay.Groups.Room, order_by: [asc: r.position]))
  end

  def get_group(_), do: nil

  @doc """
  The deposit still owed on a group. Unpaid deposit stops being due once the
  group is cancelled.
  """
  def outstanding_deposit_cents(%Group{status: "active"} = group) do
    group.deposit_due_cents - group.deposit_paid_cents
  end

  def outstanding_deposit_cents(%Group{}), do: 0

  @doc """
  The cash portion of the deposit paid on a group.
  """
  def cash_paid_cents(%Group{} = group) do
    group.deposit_paid_cents - group.credit_paid_cents
  end

  @doc """
  The cancellation policy fixed when the group was opened. Flexible groups
  booked before the policy cutoff keep the 14-day window; later flexible
  groups use the 30-day window. Advance purchase is never refundable.
  """
  def policy_version(%Group{rate_plan: "advance_purchase"}), do: "advance-nonrefundable"

  def policy_version(%Group{rate_plan: "flexible", booked_on: booked_on}) do
    if Date.compare(booked_on, @policy_cutoff) == :lt, do: "flex-14", else: "flex-30"
  end

  @doc """
  The last date on which cancelling the group is refundable, or nil for
  advance purchase.
  """
  def refundable_until(%Group{} = group) do
    refundable_until(group.arrival_on, policy_version(group))
  end

  def refundable_until(arrival_on, policy_version)

  def refundable_until(_arrival_on, "advance-nonrefundable"), do: nil

  def refundable_until(arrival_on, policy_version) do
    Date.add(arrival_on, -Map.fetch!(@flex_windows, policy_version))
  end

  @doc """
  Whether a cancellation occurring on `occurred_on` is refundable.
  """
  def refundable?(%Group{} = group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      until -> Date.compare(occurred_on, until) != :gt
    end
  end

  @doc """
  Finance totals across all groups. `as_of` sets the date used to report
  credit expiry.
  """
  def ledger(as_of \\ Date.utc_today()) do
    %{
      cash_held_cents: cash_held(),
      cash_refunded_cents: total([status: "cancelled"], :refunded_cents),
      cash_retained_cents: total([status: "cancelled"], :retained_cents),
      cash_converted_to_credit_cents: total([status: "cancelled"], :converted_to_credit_cents),
      credit_liability_cents: Credit.liability_cents(as_of)
    }
  end

  defp cash_held do
    Group
    |> where(status: "active")
    |> select([g], sum(g.deposit_paid_cents - g.credit_paid_cents))
    |> Repo.one() || 0
  end

  defp total(conditions, field) do
    Group
    |> where(^conditions)
    |> select([g], sum(field(g, ^field)))
    |> Repo.one() || 0
  end
end
