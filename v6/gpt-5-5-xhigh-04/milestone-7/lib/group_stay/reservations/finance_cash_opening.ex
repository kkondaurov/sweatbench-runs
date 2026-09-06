defmodule GroupStay.Reservations.FinanceCashOpening do
  use Ecto.Schema

  alias GroupStay.Reservations.FinanceReportingStart

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "finance_cash_openings" do
    field :property_id, :string
    field :opening_held_cents, :integer, default: 0

    belongs_to :finance_reporting_start, FinanceReportingStart

    timestamps(type: :utc_datetime_usec)
  end
end
