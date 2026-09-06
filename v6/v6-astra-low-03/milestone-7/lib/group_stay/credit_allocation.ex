defmodule GroupStay.CreditAllocation do
  use Ecto.Schema

  schema "credit_allocations" do
    field :allocation_order, :integer, default: 0
    field :group_id, :string
    field :room_id, :string
    field :credit_lot_id, :integer
    field :amount_cents, :integer
  end
end
