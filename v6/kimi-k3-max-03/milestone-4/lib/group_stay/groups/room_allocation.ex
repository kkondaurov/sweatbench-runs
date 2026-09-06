defmodule GroupStay.Groups.RoomAllocation do
  @moduledoc """
  One slice of funding applied to a room's deposit: either cash tied to its
  payment operation identifier or hotel credit tied to its original lot.
  Allocations are what cancellations settle, reductions remove, and chargebacks
  reclassify; the `disposition` of each row tells where that slice of cash or
  credit currently sits.

  Cash rows without a `payment_operation_id` form the group's unattributed
  senior block of legacy funding.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Credit.CreditLot
  alias GroupStay.Groups.Room

  @kinds ["cash", "credit"]
  @dispositions [
    "held",
    "refunded",
    "retained",
    "converted",
    "reduced",
    "charged_back",
    "settled"
  ]

  schema "room_allocations" do
    field :kind, :string
    field :amount_cents, :integer
    field :disposition, :string, default: "held"
    field :payment_operation_id, :string
    field :position, :integer

    belongs_to :room, Room
    belongs_to :credit_lot, CreditLot

    timestamps(type: :utc_datetime)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [
      :kind,
      :amount_cents,
      :disposition,
      :payment_operation_id,
      :position,
      :room_id,
      :credit_lot_id
    ])
    |> validate_required([:kind, :amount_cents, :room_id])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:disposition, @dispositions)
  end
end
