defmodule GroupStay.FinanceReporting do
  use Ecto.Schema

  schema "finance_reporting" do
    field :starts_on, :date
    field :latest_period_end_on, :date
    field :opening_credit_liability_cents, :integer

    has_many :cash_openings, GroupStay.FinanceCashOpening

    timestamps(type: :utc_datetime)
  end
end
