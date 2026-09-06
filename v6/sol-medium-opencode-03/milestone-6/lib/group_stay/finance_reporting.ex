defmodule GroupStay.FinanceReporting do
  use Ecto.Schema

  schema "finance_reporting" do
    field :singleton, :integer, default: 1
    field :starts_on, :date
    field :opening_cash, :map
    field :opening_credit_cents, :integer
    timestamps(type: :utc_datetime)
  end
end
