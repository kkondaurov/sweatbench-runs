defmodule GroupStay.Groups.CreditAllocation do
  use Ecto.Schema

  schema "credit_allocations" do
    field :amount_cents, :integer

    belongs_to :group, GroupStay.Groups.Group
    belongs_to :room, GroupStay.Groups.Room
    belongs_to :hotel_credit_lot, GroupStay.Groups.HotelCreditLot
  end
end
