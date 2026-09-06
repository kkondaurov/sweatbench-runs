defmodule GroupStay.Reservations.HotelCreditLot do
  use Ecto.Schema

  schema "hotel_credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date
    field :unrecovered_clawback_cents, :integer, default: 0

    has_many :payments, GroupStay.Reservations.GroupCreditPayment

    timestamps(type: :utc_datetime)
  end
end
