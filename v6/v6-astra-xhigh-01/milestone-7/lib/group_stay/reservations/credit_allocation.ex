defmodule GroupStay.Reservations.CreditAllocation do
  use Ecto.Schema

  schema "credit_allocations" do
    field :group_id, :string
    field :amount_cents, :integer
    belongs_to :credit_lot, GroupStay.Reservations.CreditLot
  end
end
