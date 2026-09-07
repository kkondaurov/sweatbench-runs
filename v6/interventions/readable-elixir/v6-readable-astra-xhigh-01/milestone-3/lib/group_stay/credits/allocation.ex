defmodule GroupStay.Credits.Allocation do
  @moduledoc """
  The portion of a credit lot funding a group. Applied allocations remain a
  liability regardless of the lot's expiry. Cancellation settles each allocation
  once: restored to the lot, expired on restoration, or consumed as a fee.
  """

  use Ecto.Schema

  schema "credit_allocations" do
    belongs_to :group, GroupStay.Reservations.Group, references: :group_id, type: :string
    belongs_to :credit_lot, GroupStay.Credits.Lot
    field :operation_id, :string
    field :amount_cents, :integer

    field :status, Ecto.Enum,
      values: [:applied, :restored, :expired, :consumed],
      default: :applied

    timestamps(type: :utc_datetime_usec)
  end
end
