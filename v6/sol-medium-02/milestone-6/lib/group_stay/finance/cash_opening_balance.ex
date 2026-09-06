defmodule GroupStay.Finance.CashOpeningBalance do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_cash_opening_balances" do
    field :property_id, :string
    field :opening_held_cents, :integer
  end

  def changeset(balance, attrs) do
    balance
    |> cast(attrs, [:property_id, :opening_held_cents])
    |> validate_required([:property_id, :opening_held_cents])
    |> validate_number(:opening_held_cents, greater_than: 0)
    |> unique_constraint(:property_id)
  end
end
