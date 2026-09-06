defmodule GroupStay.Reservations.FinanceClosedDailyReport do
  use Ecto.Schema

  schema "finance_closed_daily_reports" do
    field :report_date, :date
    field :data_json, :string

    timestamps(type: :utc_datetime)
  end
end
