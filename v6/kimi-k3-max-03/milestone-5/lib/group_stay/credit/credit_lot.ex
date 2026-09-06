defmodule GroupStay.Credit.CreditLot do
  @moduledoc """
  One lot of hotel credit owned by a guest. The lot is available through
  `expires_on` and expires the following day. `remaining_cents` is the portion
  not currently funding a group; allocations track the funded portion.

  `unrecovered_clawback_cents` accumulates entitlement that a chargeback could
  not remove from the lot's remaining balance. Credit returning to the lot
  absorbs that clawback before any of it becomes available again.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Credit.CreditEntitlement
  alias GroupStay.Groups.RoomAllocation

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :expires_on, :date
    field :remaining_cents, :integer, default: 0
    field :unrecovered_clawback_cents, :integer, default: 0

    has_many :allocations, RoomAllocation
    has_many :entitlements, CreditEntitlement

    timestamps(type: :utc_datetime)
  end

  def changeset(lot, attrs) do
    lot
    |> cast(attrs, [
      :guest_id,
      :source_operation_id,
      :expires_on,
      :remaining_cents,
      :unrecovered_clawback_cents
    ])
    |> validate_required([:guest_id, :source_operation_id, :expires_on, :remaining_cents])
  end
end
