defmodule GroupStay.Groups.CashAllocation do
  @moduledoc """
  Cash currently held on a room's deposit, attributed to the funding
  operation that supplied it. `operation_id` is nil for funding without a
  durable operation identity (operations submitted without one, and the
  unattributed senior block brought forward by the room-accounting
  migration).

  The integer primary key is the SQLite ROWID: insertion order is the fill
  order, so a payment's allocations can be removed in reverse fill order.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  schema "cash_allocations" do
    field :operation_id, :string
    field :amount_cents, :integer

    belongs_to :group, GroupStay.Groups.Group, type: :binary_id
    belongs_to :room, GroupStay.Groups.Room, type: :binary_id

    timestamps()
  end
end
