defmodule GroupStay.Reservations.Policy do
  @moduledoc """
  Cancellation policy versions.

  A group's policy version is decided when the group is opened and never changes afterwards:
  rescheduling moves the stay but not the policy the group was sold under. The window a version
  carries is what turns an arrival date into the last refundable cancellation date.
  """

  @flex_14 "flex-14"
  @flex_30 "flex-30"
  @advance "advance-nonrefundable"

  # New flexible bookings from this date on are sold with the wider cancellation window.
  @flex_30_from ~D[2027-01-01]

  @windows %{@flex_14 => 14, @flex_30 => 30}

  @doc """
  The policy version a group opened on `booked_on` under `rate_plan` is fixed to.
  """
  def version("advance_purchase", _booked_on), do: @advance

  def version("flexible", booked_on) do
    if Date.compare(booked_on, @flex_30_from) == :lt, do: @flex_14, else: @flex_30
  end

  @doc """
  The last date on which a cancellation is still refundable, or `nil` when the group never is.
  """
  def refundable_until(%{policy_version: version, arrival_on: arrival_on}) do
    case Map.fetch(@windows, version) do
      {:ok, days} -> Date.add(arrival_on, -days)
      :error -> nil
    end
  end

  @doc """
  Whether a cancellation on `occurred_on` is refundable. Cancelling on the boundary date is.
  """
  def refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      until -> Date.compare(occurred_on, until) != :gt
    end
  end
end
