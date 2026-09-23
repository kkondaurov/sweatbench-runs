defmodule GroupStay.CancellationPolicy do
  @moduledoc """
  Cancellation policy versions.

  A group's policy version is fixed when the group is opened, from its rate plan and booking
  date. Later changes, such as rescheduling, never move a group to a newer policy.
  """

  # Flexible groups booked on or after this date use the 30-day window.
  @flex_30_effective_on ~D[2027-01-01]

  @windows %{"flex-14" => 14, "flex-30" => 30}

  @doc "The policy version for a group opened on `booked_on` under `rate_plan`."
  def version_for("advance_purchase", _booked_on), do: "advance-nonrefundable"

  def version_for("flexible", booked_on) do
    if Date.compare(booked_on, @flex_30_effective_on) == :lt, do: "flex-14", else: "flex-30"
  end

  @doc """
  The last date on which a cancellation is refundable: the arrival date minus the policy's
  cancellation window. `nil` for non-refundable policies.
  """
  def refundable_until(version, arrival_on) do
    case Map.fetch(@windows, version) do
      {:ok, days} -> Date.add(arrival_on, -days)
      :error -> nil
    end
  end

  @doc "Whether cancelling on `cancelled_on` is refundable."
  def refundable?(version, arrival_on, cancelled_on) do
    case refundable_until(version, arrival_on) do
      nil -> false
      last_day -> Date.compare(cancelled_on, last_day) != :gt
    end
  end
end
