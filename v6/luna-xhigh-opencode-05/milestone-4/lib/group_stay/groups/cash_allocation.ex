defmodule GroupStay.Groups.CashAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "cash_allocations" do
    field :group_id, :string
    field :room_id, :integer
    field :payment_operation_id, :string
    field :amount_cents, :integer
  end

  def changeset(allocation, attrs) do
    cast(allocation, attrs, [:group_id, :room_id, :payment_operation_id, :amount_cents])
  end
end
