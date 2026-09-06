defmodule GroupStay.Groups.CreditAllocation do
  use Ecto.Schema

  schema "credit_allocations" do
    field :group_id, :string
    field :credit_lot_id, :integer
    field :amount_cents, :integer
    field :room_id, :integer
    field :operation_id, :string
    field :allocation_order, :integer
  end
end
