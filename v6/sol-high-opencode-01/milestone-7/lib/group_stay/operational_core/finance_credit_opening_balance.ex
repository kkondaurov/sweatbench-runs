defmodule GroupStay.OperationalCore.FinanceCreditOpeningBalance do
  use Ecto.Schema

  schema "finance_credit_opening_balances" do
    field :amount_cents, :integer
  end
end
