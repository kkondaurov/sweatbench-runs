defmodule GroupStay.Reservations.CreditApplication do
  @moduledoc """
  Hotel credit redeemed from one lot into one group's deposit.

  The row records which lot funded the group so the amount can be put back with its original
  expiry when the group is cancelled while refundable. `status` is the fate of that amount:

    * `applied` - funding an active group, its expiry paused;
    * `restored` - returned to its lot on a refundable cancellation;
    * `expired` - refundable cancellation found the lot's expiry already past;
    * `consumed` - kept by the hotel on a non-refundable cancellation.
  """

  use Ecto.Schema

  schema "credit_applications" do
    field :amount_cents, :integer
    field :applied_on, :date
    field :status, :string, default: "applied"

    belongs_to :group, GroupStay.Reservations.Group
    belongs_to :credit_lot, GroupStay.Reservations.CreditLot

    timestamps(type: :utc_datetime)
  end
end
