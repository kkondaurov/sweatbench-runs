defmodule GroupStay.CreditAllocation do
  use Ecto.Schema

  schema "credit_allocations" do
    field :amount_cents, :integer
    field :funding_operation_id, :string

    belongs_to :group, GroupStay.Group
    belongs_to :credit_lot, GroupStay.CreditLot
    belongs_to :room, GroupStay.Room
  end
end
