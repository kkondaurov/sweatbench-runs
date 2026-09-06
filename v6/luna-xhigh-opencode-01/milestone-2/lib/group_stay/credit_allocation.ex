defmodule GroupStay.CreditAllocation do
  use Ecto.Schema

  schema "credit_allocations" do
    field :credit_lot_id, :integer
    field :group_id, :string
    field :amount_cents, :integer
  end
end
