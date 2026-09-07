defmodule GroupStay.Reservations.CancellationPolicy do
  @moduledoc """
  Defines the cancellation promise fixed when a group is booked.

  Policy versions are stored on groups so a later change to revenue policy cannot
  silently alter an existing reservation. The migration introducing policies
  derives the same version for groups created by earlier releases.
  """

  @policy_change_on ~D[2027-01-01]

  @type version :: :flex_14 | :flex_30 | :advance_nonrefundable

  @spec version(:flexible | :advance_purchase, Date.t()) :: version()
  def version(:advance_purchase, _booked_on), do: :advance_nonrefundable

  def version(:flexible, booked_on) do
    if Date.before?(booked_on, @policy_change_on), do: :flex_14, else: :flex_30
  end

  @spec external_name(version()) :: String.t()
  def external_name(:flex_14), do: "flex-14"
  def external_name(:flex_30), do: "flex-30"
  def external_name(:advance_nonrefundable), do: "advance-nonrefundable"

  @spec refundable_until(version(), Date.t()) :: Date.t() | nil
  def refundable_until(:flex_14, arrival_on), do: Date.add(arrival_on, -14)
  def refundable_until(:flex_30, arrival_on), do: Date.add(arrival_on, -30)
  def refundable_until(:advance_nonrefundable, _arrival_on), do: nil

  @spec refundable?(version(), Date.t(), Date.t()) :: boolean()
  def refundable?(version, arrival_on, occurred_on) do
    case refundable_until(version, arrival_on) do
      nil -> false
      last_refundable_day -> not Date.after?(occurred_on, last_refundable_day)
    end
  end
end
