defmodule GroupStay.Groups.RoomAllocation do
  @moduledoc """
  The portion of one funding source currently held on one room.

  Cash and credit fund active room deposits in the rooms' original order,
  filling one room's deposit before moving to the next; `fill_order` records
  that order so funding can be removed in reverse fill order. Portions funded
  before durable operation records existed carry a nil
  `source_operation_id`: they belong to the group's unattributed senior
  block.
  """

  use Ecto.Schema

  schema "room_allocations" do
    belongs_to :group, GroupStay.Groups.Group
    belongs_to :room, GroupStay.Groups.Room
    field :kind, :string
    field :source_operation_id, :string
    belongs_to :credit_lot, GroupStay.Groups.CreditLot
    field :amount_cents, :integer
    field :fill_order, :integer

    timestamps()
  end
end
