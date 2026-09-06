defmodule GroupStay.Groups.CashAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "cash_allocations" do
    field :group_id, :string
    field :room_id, :integer
    field :payment_operation_id, :string
    field :legacy_funding_group_id, :string
    field :amount_cents, :integer
    field :allocation_order, :integer
  end

  def changeset(allocation, attrs) do
    cast(allocation, attrs, [
      :group_id,
      :room_id,
      :payment_operation_id,
      :legacy_funding_group_id,
      :amount_cents,
      :allocation_order
    ])
  end
end
