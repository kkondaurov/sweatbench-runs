defmodule GroupStay.Reservations.FinanceDailyReport do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "finance_daily_reports" do
    field :report_date, :date
    field :data, :map

    timestamps(type: :utc_datetime_usec)
  end
end
