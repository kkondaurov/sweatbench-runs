defmodule GroupStay.Reservations.HotelCreditLot do
  @moduledoc """
  A dated hotel-credit liability created by a refundable cancellation.

  `remaining_cents` is the currently available portion. Amounts applied to active reservations
  live in allocations, where their expiry is paused until settlement.
  """

  use Ecto.Schema

  schema "hotel_credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date
    field :unrecovered_clawback_cents, :integer, default: 0

    timestamps(type: :utc_datetime)
  end
end
