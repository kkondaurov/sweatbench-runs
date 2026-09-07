defmodule GroupStay.Reservations.HotelCreditAllocation do
  @moduledoc """
  Connects redeemed credit to its original lot while it funds an active group.

  Keeping this provenance lets refundable cancellation restore value without granting a second
  bonus or changing its original expiry.
  """

  use Ecto.Schema

  alias GroupStay.Reservations.{
    FundingAllocationSequence,
    GroupReservation,
    HotelCreditLot,
    Room
  }

  schema "hotel_credit_allocations" do
    field :amount_cents, :integer

    belongs_to :lot, HotelCreditLot
    belongs_to :room, Room
    belongs_to :allocation_sequence, FundingAllocationSequence

    belongs_to :group, GroupReservation,
      foreign_key: :group_id,
      references: :group_id,
      type: :string

    timestamps(type: :utc_datetime)
  end
end
