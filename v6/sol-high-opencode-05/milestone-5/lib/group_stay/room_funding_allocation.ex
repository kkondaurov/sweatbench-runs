defmodule GroupStay.RoomFundingAllocation do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "room_funding_allocations" do
    field :kind, :string
    field :source_operation_id, :string
    field :allocation_order, :integer
    field :amount_cents, :integer

    belongs_to :group, GroupStay.Group, foreign_key: :group_record_id
    belongs_to :room, GroupStay.Room, foreign_key: :room_record_id
    belongs_to :credit_lot, GroupStay.CreditLot
  end
end
