defmodule GroupStay.Credit.Funding do
  @moduledoc """
  Preserves which credit lot funded an active group's deposit and by how
  much, so a refundable cancellation can restore those amounts to their
  original lots.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "credit_fundings" do
    belongs_to :group, GroupStay.Groups.Group
    belongs_to :credit_lot, GroupStay.Credit.Lot, foreign_key: :credit_lot_id
    field :amount_cents, :integer

    timestamps()
  end

  def changeset(funding, attrs) do
    funding
    |> cast(attrs, [:group_id, :credit_lot_id, :amount_cents])
    |> validate_required([:group_id, :credit_lot_id, :amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
