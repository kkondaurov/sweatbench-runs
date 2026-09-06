defmodule GroupStay.FinanceReporting do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "finance_reporting" do
    field :starts_on, :date
    field :opening_cash, :map
    field :opening_lots, :map

    timestamps()
  end
end
