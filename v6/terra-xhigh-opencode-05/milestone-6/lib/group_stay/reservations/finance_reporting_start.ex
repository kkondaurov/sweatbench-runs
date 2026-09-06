defmodule GroupStay.Reservations.FinanceReportingStart do
  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}

  schema "finance_reporting_starts" do
    field :starts_on, :date
    field :opening_credit_liability_cents, :integer

    timestamps()
  end
end
