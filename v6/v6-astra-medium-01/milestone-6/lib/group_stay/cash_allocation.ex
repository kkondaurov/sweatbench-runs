defmodule GroupStay.CashAllocation do
  use Ecto.Schema

  schema "cash_allocations" do
    field :group_id, :string
    field :allocation_order, :integer
    field :room_id, :string
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :disposition, :string, default: "held"
  end
end
