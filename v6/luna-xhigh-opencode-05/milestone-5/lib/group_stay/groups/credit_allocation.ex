defmodule GroupStay.Groups.CreditAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "credit_allocations" do
    field :group_id, :string
    field :credit_lot_id, :integer
    field :room_id, :integer
    field :amount_cents, :integer
    field :funding_operation_id, :string
    field :allocation_order, :integer
  end

  def changeset(allocation, attrs) do
    cast(allocation, attrs, [
      :group_id,
      :credit_lot_id,
      :room_id,
      :amount_cents,
      :funding_operation_id,
      :allocation_order
    ])
  end
end
