defmodule GroupStay.Groups.RoomCashAllocation do
  @moduledoc """
  Where the cash of one recorded payment went, room by room.

  Rows are created in fill order as funding is applied, so insertion order is
  the group's funding order: legacy funding brought forward before durable
  operation records existed carries a nil `payment_operation_id` and sits
  senior to every attributed row. `allocation_seq` is one creation sequence
  shared with `GroupStay.Groups.RoomCreditApplication`, so allocations of both
  funding kinds merge into a single oldest-to-newest order across groups.
  `moved_by_transfer` marks funding that has moved between groups through a
  deposit transfer, keeping that fact after later settlements.
  `disposition` follows the cash through its life - `held`, `refunded`,
  `retained`, `converted` (then `credit_lot_id` names the issued lot),
  `reduced`, or `charged_back`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "room_cash_allocations" do
    field :payment_operation_id, :string
    field :amount_cents, :integer, default: 0
    field :disposition, :string, default: "held"
    field :credit_lot_id, :binary_id
    field :allocation_seq, :integer
    # No struct-level default: inserts omit the field and the database column
    # default (false) applies, keeping inserts usable by migrations that run
    # before the column exists.
    field :moved_by_transfer, :boolean

    belongs_to :group, GroupStay.Groups.Group
    belongs_to :room, GroupStay.Groups.Room

    timestamps(type: :utc_datetime)
  end
end
