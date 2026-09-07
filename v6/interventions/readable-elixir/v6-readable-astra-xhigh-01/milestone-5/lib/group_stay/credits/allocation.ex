defmodule GroupStay.Credits.Allocation do
  @moduledoc """
  The portion of a credit lot funding a room. Applied allocations remain a
  liability regardless of the lot's expiry. Cancellation settles each allocation
  once: restored to the lot, expired on restoration, absorbed by clawback, or
  consumed as a fee. Historical pre-upgrade settlements may have no room identity.
  Allocation order is shared with cash; a transfer creates a new portion with
  the same original lot and application identity, leaving expiry paused.
  """

  use Ecto.Schema

  schema "credit_allocations" do
    belongs_to :group, GroupStay.Reservations.Group, references: :group_id, type: :string
    belongs_to :credit_lot, GroupStay.Credits.Lot
    belongs_to :room, GroupStay.Reservations.Room
    field :operation_id, :string
    field :amount_cents, :integer
    field :allocation_order, :integer

    field :status, Ecto.Enum,
      values: [:applied, :restored, :expired, :consumed, :absorbed],
      default: :applied

    timestamps(type: :utc_datetime_usec)
  end
end
