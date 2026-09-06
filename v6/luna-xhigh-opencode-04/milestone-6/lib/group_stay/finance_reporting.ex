defmodule GroupStay.FinanceReporting do
  use Ecto.Schema

  schema "finance_reporting" do
    field :starts_on, :date
    field :opening_cash, :map
    field :opening_credit_liability_cents, :integer
    field :opening_credit_lots, :map
  end
end
