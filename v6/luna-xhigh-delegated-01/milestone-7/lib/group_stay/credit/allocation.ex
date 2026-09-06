defmodule GroupStay.Credit.Allocation do
  use Ecto.Schema

  schema "hotel_credit_allocations" do
    field :group_id, :string
    field :lot_id, :integer
    field :amount_cents, :integer
  end
end
