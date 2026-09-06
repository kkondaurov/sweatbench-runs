defmodule GroupStay.Groups.Allocation do
  @moduledoc """
  A unit of held funding allocated to a room's deposit.

  Every allocation keeps its provenance: cash allocations carry the
  `payment_operation_id` of the durable payment they came from (null for
  cash from the unattributed senior block), and credit allocations carry the
  `credit_lot_id` they were drawn from. The primary key order is the
  allocation order: funding fills rooms in room order as operations are
  processed, and draws (reductions, transfers) consume the most recently
  created allocations first. `transferred` marks allocations that have
  participated in a deposit transfer.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Credits.Lot
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room

  @kinds ~w(cash credit)

  schema "room_allocations" do
    field :kind, :string
    field :amount_cents, :integer
    field :payment_operation_id, :string
    field :transferred, :boolean, default: false

    belongs_to :room, Room
    belongs_to :group, Group
    belongs_to :credit_lot, Lot

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [
      :room_id,
      :group_id,
      :kind,
      :amount_cents,
      :payment_operation_id,
      :credit_lot_id,
      :transferred
    ])
    |> validate_required([:room_id, :group_id, :kind, :amount_cents])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:amount_cents, greater_than: 0)
    |> assoc_constraint(:room)
    |> assoc_constraint(:group)
    |> assoc_constraint(:credit_lot)
  end
end
