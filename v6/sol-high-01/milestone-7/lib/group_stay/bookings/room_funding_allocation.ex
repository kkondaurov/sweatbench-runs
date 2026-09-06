defmodule GroupStay.Bookings.RoomFundingAllocation do
  use Ecto.Schema

  alias GroupStay.Bookings.{CreditLot, Room}

  schema "room_funding_allocations" do
    field :funding_type, :string
    field :payment_operation_id, :string
    field :funding_operation_id, :string
    field :amount_cents, :integer

    belongs_to :room, Room
    belongs_to :credit_lot, CreditLot
  end
end
