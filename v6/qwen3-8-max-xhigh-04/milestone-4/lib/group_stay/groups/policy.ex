defmodule GroupStay.Groups.Policy do
  @moduledoc """
  Cancellation policy versions for group reservations.

  A group's policy version is fixed when the group is opened. Rescheduling a
  group never moves it to a newer policy.
  """

  @policy_change_date ~D[2027-01-01]
  @windows %{"flex-14" => 14, "flex-30" => 30}

  @doc """
  Returns the policy version for a group opened with the given rate plan on
  the given booking date.
  """
  def version_for("flexible", booked_on) do
    if Date.compare(booked_on, @policy_change_date) == :lt do
      "flex-14"
    else
      "flex-30"
    end
  end

  def version_for("advance_purchase", _booked_on), do: "advance-nonrefundable"

  @doc """
  Returns whether a cancellation of the group on the given date is refundable.
  """
  def refundable?(%{policy_version: version, arrival_on: arrival_on}, occurred_on) do
    case Map.fetch(@windows, version) do
      {:ok, window} -> Date.diff(arrival_on, occurred_on) >= window
      :error -> false
    end
  end

  @doc """
  Returns the last date on which the group can be cancelled refundably, or
  `nil` for non-refundable policies.
  """
  def refundable_until(%{policy_version: version, arrival_on: arrival_on}) do
    case Map.fetch(@windows, version) do
      {:ok, window} -> Date.add(arrival_on, -window)
      :error -> nil
    end
  end

  @doc """
  Returns `refundable_until/1` as an ISO 8601 string, or `nil`.
  """
  def refundable_until_iso(group) do
    case refundable_until(group) do
      nil -> nil
      date -> Date.to_iso8601(date)
    end
  end
end
