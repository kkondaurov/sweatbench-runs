defmodule GroupStay.Reservations.CashAllocation do
  use Ecto.Schema

  alias GroupStay.Reservations.{Group, Room}

  schema "cash_allocations" do
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :allocation_sequence, :integer

    belongs_to :group, Group,
      foreign_key: :group_id,
      references: :group_id,
      type: :string

    belongs_to :room, Room

    timestamps(type: :utc_datetime)
  end
end
