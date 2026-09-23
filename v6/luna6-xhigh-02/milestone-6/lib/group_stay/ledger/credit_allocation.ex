defmodule GroupStay.Ledger.CreditAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "group_credit_allocations" do
    field :amount_cents, :integer
    field :room_id, :string
    field :source_operation_id, :string
    field :allocation_order_id, :integer

    belongs_to :group, GroupStay.Groups.Group,
      foreign_key: :group_id,
      references: :group_id,
      type: :string

    belongs_to :credit_lot, GroupStay.Ledger.CreditLot

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [
      :group_id,
      :credit_lot_id,
      :amount_cents,
      :room_id,
      :source_operation_id,
      :allocation_order_id
    ])
    |> validate_required([:group_id, :credit_lot_id, :amount_cents, :allocation_order_id])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
