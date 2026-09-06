defmodule GroupStay.RoomAccounting.RoomAllocation do
  @moduledoc """
  One contiguous slice of a room's deposit funding.

  A row holds either cash or hotel credit applied to one room. `disposition`
  starts as `held` and is reclassified when the slice leaves the room's
  deposit: `refunded`, `retained`, or `converted` on settlement, `reduced` by
  a provider correction, and `charged_back` when the funding payment is
  reversed. Rows created while this release is deployed carry a globally
  increasing `seq`, so held cash can be drained in reverse fill order even
  when one payment's funding spans several groups.
  """

  use Ecto.Schema

  alias GroupStay.Credit.CreditLot
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "room_allocations" do
    field :kind, :string
    field :amount_cents, :integer
    field :payment_operation_id, :string
    field :disposition, :string, default: "held"
    field :seq, :integer

    belongs_to :group, Group
    belongs_to :room, Room
    belongs_to :lot, CreditLot

    timestamps()
  end
end
