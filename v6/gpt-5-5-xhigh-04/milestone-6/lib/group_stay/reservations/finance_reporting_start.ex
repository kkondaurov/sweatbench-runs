defmodule GroupStay.Reservations.FinanceReportingStart do
  use Ecto.Schema

  alias GroupStay.Reservations.FinanceCashOpening

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "finance_reporting_starts" do
    field :singleton_key, :string
    field :operation_id, :string
    field :starts_on, :date
    field :opening_credit_liability_cents, :integer, default: 0

    has_many :cash_openings, FinanceCashOpening

    timestamps(type: :utc_datetime_usec)
  end
end
