defmodule GroupStay.HotelCreditAllocation do
  use Ecto.Schema

  schema "hotel_credit_allocations" do
    field :amount_cents, :integer
    field :room_id, :string
    field :funding_operation_id, :string

    belongs_to :credit_lot, GroupStay.HotelCreditLot

    belongs_to :reservation, GroupStay.Reservation,
      foreign_key: :group_id,
      references: :group_id,
      type: :string

    timestamps(type: :utc_datetime)
  end
end
