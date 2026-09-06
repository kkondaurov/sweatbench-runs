defmodule GroupStay.Reservations.CreditApplication do
  @moduledoc """
  Hotel credit redeemed from one lot into one room's deposit.

  The row records which lot funded which room, so the amount can be put back with its original
  expiry when that room is settled while refundable. `status` is the fate of that amount:

    * `applied` - funding an active room, its expiry paused;
    * `restored` - returned to its lot on a refundable settlement;
    * `expired` - a refundable settlement found the lot's expiry already past;
    * `consumed` - kept by the hotel on a non-refundable settlement;
    * `absorbed` - taken entirely by clawback the lot had not recovered.

  `absorbed_cents` is the part of a returning amount that a chargeback's unrecovered clawback took
  before any remainder could become available again.
  """

  use Ecto.Schema

  schema "credit_applications" do
    field :amount_cents, :integer
    field :applied_on, :date
    field :status, :string, default: "applied"
    field :absorbed_cents, :integer, default: 0

    belongs_to :group, GroupStay.Reservations.Group
    belongs_to :room, GroupStay.Reservations.Room
    belongs_to :credit_lot, GroupStay.Reservations.CreditLot

    timestamps(type: :utc_datetime)
  end
end
