defmodule GroupStay.Funding.Allocation do
  @moduledoc """
  Cash or hotel credit funding one room's deposit.

  A row records where the money came from and where it currently stands.
  `operation_id` is the durable operation that recorded the funding, or `nil` for
  the unattributed block carried forward from before durable records existed.

  Rows are inserted in funding order, so the primary key is also the fill order a
  reduction or a chargeback unwinds.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Credit.Lot
  alias GroupStay.Reservations.Group
  alias GroupStay.Reservations.Room

  @kinds ~w(cash credit)

  # Cash is held until it is settled by a cancellation, corrected by a reduction,
  # or reversed by a chargeback. Credit is held until a settlement either returns
  # it to its lot or consumes it.
  @dispositions ~w(held refunded retained converted reduced charged_back restored consumed)

  schema "room_allocations" do
    field :kind, :string
    field :operation_id, :string
    field :amount_cents, :integer
    field :disposition, :string

    belongs_to :group, Group, foreign_key: :group_ref
    belongs_to :room, Room, foreign_key: :room_ref
    belongs_to :lot, Lot, foreign_key: :lot_ref
    belongs_to :issued_lot, Lot, foreign_key: :issued_lot_ref

    timestamps(type: :utc_datetime_usec)
  end

  @fields [
    :group_ref,
    :room_ref,
    :kind,
    :operation_id,
    :lot_ref,
    :issued_lot_ref,
    :amount_cents,
    :disposition
  ]

  @required [:group_ref, :room_ref, :kind, :amount_cents, :disposition]

  @doc "Cash dispositions a chargeback reclassifies."
  def chargeable, do: ~w(held refunded retained converted)

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, @fields)
    |> validate_required(@required)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:disposition, @dispositions)
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
