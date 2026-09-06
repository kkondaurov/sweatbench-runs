defmodule GroupStay.CreditAllocation do
  use Ecto.Schema

  schema "credit_allocations" do
    field :amount_cents, :integer

    belongs_to :group, GroupStay.Group
    belongs_to :credit_lot, GroupStay.CreditLot
  end
end
