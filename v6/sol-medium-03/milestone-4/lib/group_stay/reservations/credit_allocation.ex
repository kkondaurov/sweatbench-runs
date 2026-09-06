defmodule GroupStay.Reservations.CreditAllocation do
  use Ecto.Schema

  alias GroupStay.Reservations.{CreditLot, Group, Room}

  schema "credit_allocations" do
    field :amount_cents, :integer
    field :funding_operation_id, :string

    belongs_to :group, Group,
      foreign_key: :group_id,
      references: :group_id,
      type: :string

    belongs_to :credit_lot, CreditLot
    belongs_to :room, Room

    timestamps(type: :utc_datetime)
  end
end
