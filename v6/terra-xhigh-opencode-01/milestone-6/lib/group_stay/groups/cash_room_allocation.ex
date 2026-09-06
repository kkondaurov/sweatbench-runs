defmodule GroupStay.Groups.CashRoomAllocation do
  use Ecto.Schema

  schema "cash_room_allocations" do
    field :amount_cents, :integer
    field :allocation_order, :integer

    belongs_to :room, GroupStay.Groups.Room
    belongs_to :cash_payment_source, GroupStay.Groups.CashPaymentSource
  end
end
