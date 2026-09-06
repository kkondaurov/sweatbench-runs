defmodule GroupStay.CashAllocation do
  use Ecto.Schema

  import Ecto.Changeset

  schema "cash_allocations" do
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :disposition, :string
    field :allocation_order, :integer
    field :transferred, :boolean

    belongs_to :group, GroupStay.Group, foreign_key: :group_record_id
    belongs_to :room, GroupStay.GroupRoom, foreign_key: :group_room_id
    belongs_to :credit_lot, GroupStay.CreditLot, foreign_key: :credit_lot_id
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [
      :group_record_id,
      :group_room_id,
      :payment_operation_id,
      :amount_cents,
      :disposition,
      :credit_lot_id,
      :allocation_order,
      :transferred
    ])
    |> validate_required([:group_record_id, :group_room_id, :amount_cents, :disposition])
  end
end
