defmodule GroupStay.FinanceReporting do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: false}

  schema "finance_reporting" do
    field :starts_on, :date
    field :opening_cash_json, :string
    field :opening_credit_liability_cents, :integer
    field :opening_credit_lots_json, :string
  end
end
