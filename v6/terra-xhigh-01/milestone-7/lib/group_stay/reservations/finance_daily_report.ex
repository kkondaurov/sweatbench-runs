defmodule GroupStay.Reservations.FinanceDailyReport do
  @moduledoc false

  use Ecto.Schema

  schema "finance_daily_reports" do
    field :report_on, :date
    field :data, :map

    belongs_to :finance_reporting, GroupStay.Reservations.FinanceReporting

    timestamps(type: :utc_datetime)
  end
end
