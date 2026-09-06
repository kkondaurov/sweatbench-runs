defmodule GroupStay.Groups.CreditAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "credit_allocations" do
    field :group_id, :string
    field :credit_lot_id, :integer
    field :amount_cents, :integer
  end

  def changeset(allocation, attrs) do
    cast(allocation, attrs, [:group_id, :credit_lot_id, :amount_cents])
  end
end
