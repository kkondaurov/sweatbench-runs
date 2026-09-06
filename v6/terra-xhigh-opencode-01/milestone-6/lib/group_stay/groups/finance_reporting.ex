defmodule GroupStay.Groups.FinanceReporting do
  use Ecto.Schema

  schema "finance_reporting" do
    field :reporting_key, :integer
    field :starts_on, :date
    field :opening_credit_liability_cents, :integer
  end
end
