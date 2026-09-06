defmodule GroupStay.Reservations.FinanceClosedDailyReport do
  use Ecto.Schema

  schema "finance_closed_daily_reports" do
    field :reporting_start_id, :integer
    field :date, :date
    field :data, :string

    timestamps()
  end
end
