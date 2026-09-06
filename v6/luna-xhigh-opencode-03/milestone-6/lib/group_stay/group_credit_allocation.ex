defmodule GroupStay.GroupCreditAllocation do
  use Ecto.Schema

  import Ecto.Changeset

  schema "group_credit_allocations" do
    field :amount_cents, :integer
    field :source_operation_id, :string
    field :status, :string
    field :allocation_order, :integer

    belongs_to :group, GroupStay.Group, foreign_key: :group_record_id
    belongs_to :room, GroupStay.GroupRoom, foreign_key: :group_room_id
    belongs_to :credit_lot, GroupStay.CreditLot, foreign_key: :credit_lot_id
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [
      :group_record_id,
      :group_room_id,
      :credit_lot_id,
      :amount_cents,
      :source_operation_id,
      :status,
      :allocation_order
    ])
    |> validate_required([:group_record_id, :credit_lot_id, :amount_cents, :status])
  end
end
