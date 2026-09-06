defmodule GroupStay.Allocations.RoomAllocation do
  @moduledoc """
  A portion of a room's deposit funded by one source: a recorded cash
  payment, an applied hotel-credit application, or funding carried over from
  before durable operation records existed (which has no source operation).

  The row's state records the current disposition of that funding: `held` on
  an active room, or settled as `refunded`, `retained`, `restored`,
  `consumed`, `converted`, `reduced`, or `charged_back`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "room_allocations" do
    field :kind, :string
    field :source_operation_id, :string
    field :amount_cents, :integer
    field :state, :string, default: "held"
    field :position, :integer, default: 0

    belongs_to :group, GroupStay.Groups.Group
    belongs_to :room, GroupStay.Groups.Room
    belongs_to :credit_lot, GroupStay.Credits.CreditLot

    timestamps(type: :utc_datetime)
  end
end
