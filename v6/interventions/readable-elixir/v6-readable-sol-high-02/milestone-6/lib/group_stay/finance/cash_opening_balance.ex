defmodule GroupStay.Finance.CashOpeningBalance do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:property_id, :string, autogenerate: false}

  schema "finance_cash_opening_balances" do
    field :amount_cents, :integer
  end

  def changeset(balance, attrs) do
    balance
    |> cast(attrs, [:property_id, :amount_cents])
    |> validate_required([:property_id, :amount_cents])
  end
end
