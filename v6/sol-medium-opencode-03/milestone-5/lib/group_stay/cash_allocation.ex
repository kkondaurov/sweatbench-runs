defmodule GroupStay.CashAllocation do
  use Ecto.Schema

  alias GroupStay.{AllocationOrder, CashPayment, Room}

  schema "cash_allocations" do
    field :amount_cents, :integer
    belongs_to :room, Room
    belongs_to :cash_payment, CashPayment
    belongs_to :allocation_order, AllocationOrder
    timestamps(type: :utc_datetime)
  end
end
