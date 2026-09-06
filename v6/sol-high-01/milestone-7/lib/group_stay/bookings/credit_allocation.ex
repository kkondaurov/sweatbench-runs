defmodule GroupStay.Bookings.CreditAllocation do
  use Ecto.Schema

  alias GroupStay.Bookings.{CreditLot, Group}

  schema "credit_allocations" do
    field :amount_cents, :integer

    belongs_to :credit_lot, CreditLot

    belongs_to :group, Group,
      foreign_key: :group_id,
      references: :group_id,
      type: :string
  end
end
