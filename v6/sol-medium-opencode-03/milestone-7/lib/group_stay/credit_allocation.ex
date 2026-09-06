defmodule GroupStay.CreditAllocation do
  use Ecto.Schema

  alias GroupStay.{AllocationOrder, CreditLot, Group, Room}

  schema "credit_allocations" do
    field :amount_cents, :integer
    field :funding_operation_id, :string

    belongs_to :credit_lot, CreditLot
    belongs_to :group, Group, foreign_key: :group_record_id
    belongs_to :room, Room
    belongs_to :allocation_order, AllocationOrder

    timestamps(type: :utc_datetime)
  end
end
