defmodule GroupStay.Groups.Funding do
  @moduledoc """
  One slice of a group's deposit funding held on one room.

  `kind` is `cash` for an applied cash payment or `credit` for redeemed
  hotel credit. `operation_id` is the durable partner operation behind the
  funding (`record_cash_payment` or `apply_hotel_credit`); `nil` marks the
  unattributed senior block brought forward from before durable operation
  records existed. Credit fundings keep their `credit_lot_id` so a
  refundable cancellation can restore the amount to its original lot.

  Rows are appended in allocation order: the legacy block first, then each
  durable operation in commit order, filling active rooms in their original
  order. Insertion order therefore doubles as fill order, which reverse-fill
  removals and clawback attribution rely on.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(cash credit)

  schema "room_fundings" do
    belongs_to :group, GroupStay.Groups.Group
    belongs_to :room, GroupStay.Groups.Room
    field :kind, :string
    field :operation_id, :string
    belongs_to :credit_lot, GroupStay.Credit.Lot, foreign_key: :credit_lot_id
    field :amount_cents, :integer

    timestamps()
  end

  def kinds, do: @kinds

  def changeset(funding, attrs) do
    funding
    |> cast(attrs, [:group_id, :room_id, :kind, :operation_id, :credit_lot_id, :amount_cents])
    |> validate_required([:group_id, :room_id, :kind, :amount_cents])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
