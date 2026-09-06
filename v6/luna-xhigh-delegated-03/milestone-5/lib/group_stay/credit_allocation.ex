defmodule GroupStay.CreditAllocation do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :string
  schema "credit_allocations" do
    field :group_id, :string
    field :credit_lot_id, :integer
    field :amount_cents, :integer
    field :room_id, :string
    field :source_operation_id, :string
    field :allocation_order, :integer, default: 0
  end
end
