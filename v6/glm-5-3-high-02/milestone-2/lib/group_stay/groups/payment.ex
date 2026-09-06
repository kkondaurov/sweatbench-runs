defmodule GroupStay.Groups.Payment do
  @moduledoc """
  Cash applied to a group deposit.

  A payment starts as `held` cash and moves to `refunded`, `retained`, or
  `converted` (issued as hotel credit) when its group is cancelled.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Groups.Group

  schema "payments" do
    belongs_to :group, Group
    field :amount_cents, :integer
    field :state, :string, default: "held"
    field :recorded_on, :date

    timestamps()
  end

  def changeset(payment, attrs) do
    payment
    |> cast(attrs, [:group_id, :amount_cents, :state, :recorded_on])
    |> validate_required([:group_id, :amount_cents, :state, :recorded_on])
    |> validate_inclusion(:state, ~w(held refunded retained converted))
    |> foreign_key_constraint(:group_id)
  end
end
