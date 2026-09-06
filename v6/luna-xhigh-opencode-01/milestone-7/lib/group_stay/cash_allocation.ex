defmodule GroupStay.CashAllocation do
  use Ecto.Schema

  schema "cash_allocations" do
    field :payment_operation_id, :string
    field :group_id, :string
    field :room_id, :string
    field :amount_cents, :integer
    field :allocation_order, :integer
  end
end
