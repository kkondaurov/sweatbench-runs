defmodule GroupStay.Bookings.CreditAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Bookings.{CreditLot, Group, Operation, Room}

  schema "credit_allocations" do
    field :amount_cents, :integer
    field :funding_operation_id, :string

    belongs_to :credit_lot, CreditLot
    belongs_to :group, Group, references: :group_id, type: :string
    belongs_to :room, Room

    belongs_to :funding_operation, Operation,
      references: :operation_id,
      foreign_key: :funding_operation_id,
      type: :string,
      define_field: false
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [
      :credit_lot_id,
      :group_id,
      :room_id,
      :funding_operation_id,
      :amount_cents
    ])
    |> validate_required([:credit_lot_id, :group_id, :amount_cents])
  end
end
