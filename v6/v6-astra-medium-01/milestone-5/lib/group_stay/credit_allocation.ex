defmodule GroupStay.CreditAllocation do
  use Ecto.Schema

  schema "credit_allocations" do
    field :allocation_order, :integer
    field :room_id, :string
    field :operation_id, :string
    field :group_id, :string
    field :credit_lot_id, :id
    field :amount_cents, :integer
  end
end
