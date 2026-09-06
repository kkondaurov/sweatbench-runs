defmodule GroupStay.CashAllocation do
  use Ecto.Schema

  alias GroupStay.Room

  schema "cash_allocations" do
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :allocation_order, :integer
    belongs_to :room, Room
  end
end
