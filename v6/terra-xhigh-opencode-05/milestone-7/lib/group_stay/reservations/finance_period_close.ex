defmodule GroupStay.Reservations.FinancePeriodClose do
  use Ecto.Schema

  schema "finance_period_closes" do
    field :reporting_start_id, :integer
    field :period_end_on, :date

    timestamps()
  end
end
