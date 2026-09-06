defmodule GroupStay.CashAllocation do
  use Ecto.Schema

  schema "cash_allocations" do
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :allocation_order, :integer

    belongs_to :group, GroupStay.Group
    belongs_to :room, GroupStay.Room
  end
end
