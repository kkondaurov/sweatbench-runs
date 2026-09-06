defmodule GroupStay.Credit.Application do
  @moduledoc """
  Credit from a lot applied to a group's deposit.

  An application starts as `applied` while it funds an active group, which
  pauses the lot's expiry for that amount. A refundable cancellation moves
  it back to `restored` (its lot regains the amount); a non-refundable
  cancellation moves it to `consumed` without restoring the lot.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Credit.Lot
  alias GroupStay.Groups.Group

  schema "credit_applications" do
    belongs_to :group, Group
    belongs_to :lot, Lot
    field :amount_cents, :integer
    field :state, :string, default: "applied"

    timestamps()
  end

  def changeset(application, attrs) do
    application
    |> cast(attrs, [:group_id, :lot_id, :amount_cents, :state])
    |> validate_required([:group_id, :lot_id, :amount_cents, :state])
    |> validate_inclusion(:state, ~w(applied restored consumed))
    |> validate_number(:amount_cents, greater_than: 0)
    |> foreign_key_constraint(:group_id)
    |> foreign_key_constraint(:lot_id)
  end
end
