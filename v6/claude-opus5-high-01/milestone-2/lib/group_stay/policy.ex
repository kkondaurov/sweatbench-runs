defmodule GroupStay.Policy do
  @moduledoc """
  Cancellation policy versions.

  A group's version is fixed when the group is opened and is derived from its rate
  plan and booking date. Rescheduling a group never moves it to a newer version,
  so the version is stored rather than recomputed from the current stay.
  """

  @flex_30_booked_from ~D[2027-01-01]

  @versions ~w(flex-14 flex-30 advance-nonrefundable)

  @doc "Every policy version GroupStay issues."
  def versions, do: @versions

  @doc "The policy version a group opened on `booked_on` under `rate_plan` receives."
  def version_for("flexible", booked_on) do
    if Date.before?(booked_on, @flex_30_booked_from), do: "flex-14", else: "flex-30"
  end

  def version_for("advance_purchase", _booked_on), do: "advance-nonrefundable"

  @doc "Cancellation window in days, or `nil` when the policy is never refundable."
  def window_days("flex-14"), do: 14
  def window_days("flex-30"), do: 30
  def window_days("advance-nonrefundable"), do: nil

  @doc """
  The last date on which cancelling still refunds, or `nil` when the policy is
  never refundable. Cancelling on that date is still refundable.
  """
  def refundable_until(policy_version, arrival_on) do
    case window_days(policy_version) do
      nil -> nil
      days -> Date.add(arrival_on, -days)
    end
  end

  @doc "True when cancelling on `on` refunds what the group has paid."
  def refundable?(policy_version, arrival_on, on) do
    case refundable_until(policy_version, arrival_on) do
      nil -> false
      until -> not Date.after?(on, until)
    end
  end
end
