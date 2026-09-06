defmodule GroupStay.Groups.RoomAllocation do
  @moduledoc """
  One portion of funding allocated to a room's deposit.

  Cash allocations carry the `operation_id` of the durably recorded payment
  that supplied them (nil for the unattributed senior block carried forward
  from before durable operation records); credit allocations additionally
  carry the `lot_id` of the credit lot they were redeemed from, so they can
  be restored to that lot on a refundable settlement.

  `disposition` is the current classification of the funding: `held` while it
  funds an active room's deposit, then `refunded`, `retained`, or `converted`
  once the room is settled, `reduced` when a provider correction removes it,
  or `charged_back` when the payment that supplied it is charged back.
  """

  use Ecto.Schema

  schema "room_allocations" do
    field :operation_id, :string
    field :kind, :string
    field :amount_cents, :integer
    field :disposition, :string, default: "held"

    belongs_to :group, GroupStay.Groups.Group,
      foreign_key: :group_id,
      references: :group_id,
      type: :string

    belongs_to :room, GroupStay.Groups.Room, foreign_key: :room_id
    belongs_to :lot, GroupStay.Credit.Lot, foreign_key: :lot_id

    timestamps(type: :utc_datetime)
  end
end
