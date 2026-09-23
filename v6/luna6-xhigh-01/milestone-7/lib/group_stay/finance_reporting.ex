defmodule GroupStay.FinanceReporting do
  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}
  schema "finance_reporting" do
    field :starts_on, :date
    field :latest_closed_on, :date
    field :opening_cash_by_property, :map
    field :opening_credit_liability_cents, :integer

    timestamps(type: :utc_datetime)
  end
end
