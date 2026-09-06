defmodule GroupStay.Reservations.FinanceReportingStart do
  use Ecto.Schema

  schema "finance_reporting_starts" do
    field :singleton_key, :integer, default: 1
    field :operation_id, :string
    field :starts_on, :date
    field :opening_credit_liability_cents, :integer, default: 0

    timestamps(type: :utc_datetime)
  end
end
