defmodule GroupStay.Groups.FinanceDailyReport do
  use Ecto.Schema

  schema "finance_daily_reports" do
    field :report_on, :date
    field :data, :map

    belongs_to :finance_reporting, GroupStay.Groups.FinanceReporting
  end
end
