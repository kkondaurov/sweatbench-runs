defmodule GroupStay.Groups.Allocation do
  @moduledoc """
  A slice of deposit funding applied to one room.

  Allocations are filled room by room, in the rooms' original order, each
  funding operation in processing order. A cash allocation carries the
  `operation_id` of the payment that supplied it (nil for funding from
  before durable operation records); a credit allocation also carries the
  lot it was drawn from, and a converted cash allocation carries the lot it
  created.

  Cash states: `held`, `refunded`, `retained`, `converted`, `reduced`,
  `charged_back`. Credit states: `held`, `restored`, `consumed`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Credit.Lot
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room

  schema "room_allocations" do
    belongs_to :group, Group
    belongs_to :room, Room
    field :source, :string
    field :operation_id, :string
    belongs_to :lot, Lot
    field :amount_cents, :integer
    field :state, :string

    timestamps()
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:group_id, :room_id, :source, :operation_id, :lot_id, :amount_cents, :state])
    |> validate_required([:group_id, :room_id, :source, :amount_cents, :state])
    |> validate_inclusion(:source, ~w(cash credit))
    |> validate_inclusion(
      :state,
      ~w(held refunded retained converted reduced charged_back restored consumed)
    )
    |> validate_number(:amount_cents, greater_than: 0)
    |> foreign_key_constraint(:group_id)
    |> foreign_key_constraint(:room_id)
    |> foreign_key_constraint(:lot_id)
  end
end
