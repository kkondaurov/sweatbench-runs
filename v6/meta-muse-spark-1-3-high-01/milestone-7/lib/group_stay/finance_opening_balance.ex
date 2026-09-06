defmodule GroupStay.FinanceOpeningBalance do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_opening_balances" do
    field :state_id, :integer
    field :kind, :string
    field :property_id, :string
    field :amount_cents, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [:state_id, :kind, :property_id, :amount_cents])
    |> validate_required([:state_id, :kind, :amount_cents])
  end
end
