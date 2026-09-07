defmodule GroupStay.Reservations.CancellationPolicy do
  @moduledoc """
  Defines the cancellation promise fixed when a group is booked.

  Policy versions are persisted on new groups. `version/1` also derives the version for records
  written by an older release, which keeps rolling upgrades and partially migrated data readable.
  """

  alias GroupStay.Reservations.GroupReservation

  @new_flexible_policy_on ~D[2027-01-01]

  def version(%GroupReservation{policy_version: version}) when is_binary(version), do: version

  def version(%GroupReservation{rate_plan: rate_plan, booked_on: booked_on}),
    do: version(rate_plan, booked_on)

  def version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  def version("flexible", booked_on) do
    if Date.before?(booked_on, @new_flexible_policy_on), do: "flex-14", else: "flex-30"
  end

  def refundable_until(%GroupReservation{} = group) do
    case version(group) do
      "flex-14" -> Date.add(group.arrival_on, -14)
      "flex-30" -> Date.add(group.arrival_on, -30)
      "advance-nonrefundable" -> nil
    end
  end

  def refundable?(%GroupReservation{} = group, cancelled_on) do
    case refundable_until(group) do
      nil -> false
      deadline -> not Date.after?(cancelled_on, deadline)
    end
  end
end
