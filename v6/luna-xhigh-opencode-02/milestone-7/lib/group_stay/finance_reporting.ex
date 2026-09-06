defmodule GroupStay.FinanceReporting do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: false}

  schema "finance_reporting" do
    field :starts_on, :date
    field :latest_close_on, :date
    field :opening_cash, :map
    field :opening_credit_cents, :integer
    field :opening_credit_lots, :map
  end
end
