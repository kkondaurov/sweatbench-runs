defmodule GroupStay.CreditAllocation do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :string
  schema "credit_allocations" do
    field :group_id, :string
    field :credit_lot_id, :integer
    field :amount_cents, :integer
  end
end
