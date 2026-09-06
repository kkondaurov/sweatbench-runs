defmodule GroupStay.OperationalCore.FinanceCashOpeningBalance do
  use Ecto.Schema

  schema "finance_cash_opening_balances" do
    field :property_id, :string
    field :amount_cents, :integer
  end
end
