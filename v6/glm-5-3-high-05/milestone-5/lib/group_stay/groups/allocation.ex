defmodule GroupStay.Groups.Allocation do
  @moduledoc """
  One room's share of a funding event.

  A cash payment or hotel-credit application fills the active rooms' deposits
  in their original order, one room's deposit before the next; each chunk of
  that fill becomes an allocation row. The integer primary key preserves the
  order in which allocations were created, which is the fill order used by
  room accounting.

  `remaining_cents` is the amount currently held on the room; it decreases
  when a reduction or chargeback removes held cash and moves to
  `settled_cents` when the room is cancelled. Cash allocations reference the
  cash-payment ledger entry they came from; credit allocations reference the
  credit application (and through it the lot) they came from.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "room_allocations" do
    field :kind, :string
    field :amount_cents, :integer
    field :remaining_cents, :integer, default: 0
    field :settled_cents, :integer, default: 0

    belongs_to :group, GroupStay.Groups.Group
    belongs_to :room, GroupStay.Groups.Room
    belongs_to :payment_entry, GroupStay.Ledger.Entry
    belongs_to :credit_application, GroupStay.Credit.Application

    timestamps()
  end

  def changeset(allocation, attrs) do
    allocation
    |> Ecto.Changeset.cast(attrs, [
      :kind,
      :amount_cents,
      :remaining_cents,
      :settled_cents,
      :group_id,
      :room_id,
      :payment_entry_id,
      :credit_application_id
    ])
    |> Ecto.Changeset.validate_required([
      :kind,
      :amount_cents,
      :remaining_cents,
      :group_id,
      :room_id
    ])
    |> Ecto.Changeset.validate_inclusion(:kind, ~w(cash credit))
    |> Ecto.Changeset.validate_number(:amount_cents, greater_than: 0)
    |> Ecto.Changeset.validate_number(:remaining_cents, greater_than_or_equal_to: 0)
    |> Ecto.Changeset.validate_number(:settled_cents, greater_than_or_equal_to: 0)
    |> Ecto.Changeset.assoc_constraint(:group)
    |> Ecto.Changeset.assoc_constraint(:room)
  end
end
