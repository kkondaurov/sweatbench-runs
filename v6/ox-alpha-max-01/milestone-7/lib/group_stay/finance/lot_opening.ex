defmodule GroupStay.Finance.LotOpening do
  @moduledoc """
  One credit lot's available (unapplied) balance at the reporting opening
  position.

  Expiry is never an operation, so the daily report derives each lot's expiry
  movement from this baseline plus the recorded application, restoration, and
  revocation movements posted before the lot's `expires_on`. Lots born after
  reporting started have no row here; their issued amount is their baseline.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_lot_openings" do
    field :credit_lot_id, :id
    field :available_cents, :integer, default: 0

    timestamps()
  end

  def changeset(opening, attrs) do
    opening
    |> cast(attrs, [:credit_lot_id, :available_cents])
    |> validate_required([:credit_lot_id, :available_cents])
    |> unique_constraint(:credit_lot_id)
  end
end
