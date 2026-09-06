defmodule GroupStay.Reservations.CreditAllocation do
  use Ecto.Schema

  alias GroupStay.Reservations.{CreditLot, Group}

  schema "credit_allocations" do
    field :amount_cents, :integer

    belongs_to :group, Group,
      foreign_key: :group_id,
      references: :group_id,
      type: :string

    belongs_to :credit_lot, CreditLot

    timestamps(type: :utc_datetime)
  end
end
