defmodule GroupStay.OperationalCore.CreditAllocation do
  use Ecto.Schema

  schema "credit_allocations" do
    field :group_id, :string
    field :credit_lot_id, :integer
    field :room_id, :integer
    field :funding_operation_id, :string
    field :amount_cents, :integer
    field :allocation_order, :integer
  end
end
