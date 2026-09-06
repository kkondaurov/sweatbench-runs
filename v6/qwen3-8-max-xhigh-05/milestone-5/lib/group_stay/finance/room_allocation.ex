defmodule GroupStay.Finance.RoomAllocation do
  @moduledoc """
  One portion of one funding source held on one room.

  Cash and credit fund active rooms in the rooms' original order, filling one
  room's deposit before moving to the next, and each funding operation
  appends its allocations in operation-processing order. The auto-incrementing
  `id` therefore preserves fill order.

  `funding_operation_id` identifies the durable operation record of the
  funding: an applied `record_cash_payment` for cash or an applied
  `apply_hotel_credit` for credit. It is nil for the unattributed senior
  block carried forward from funding that predates durable operation records.

  For credit allocations `lot_id` is the credit lot consumed. For cash
  allocations `lot_id` is set when a settlement converts the cash into a
  credit lot, recording which lot the conversion funded.

  Cash dispositions are `held`, `refunded`, `retained`, `converted`,
  `reduced`, and `charged_back`. Credit allocations are `held` until a
  settlement `restored` or `consumed` them. A deposit transfer moves held
  funding to another group's rooms: the moved portion becomes a new held
  allocation there, and a fully moved allocation is left behind as
  `transferred` history.

  `transferred` marks allocations created by a deposit transfer, so a cash
  payment's participation in transfers survives later settlements.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "room_allocations" do
    field :kind, :string
    field :funding_operation_id, :string
    field :amount_cents, :integer
    field :status, :string, default: "held"
    field :transferred, :boolean, default: false

    belongs_to :group, GroupStay.Groups.Group
    belongs_to :room, GroupStay.Groups.Room
    belongs_to :lot, GroupStay.Finance.CreditLot

    timestamps(type: :utc_datetime)
  end
end
