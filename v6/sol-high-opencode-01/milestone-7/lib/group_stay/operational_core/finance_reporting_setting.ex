defmodule GroupStay.OperationalCore.FinanceReportingSetting do
  use Ecto.Schema

  schema "finance_reporting_settings" do
    field :singleton, :boolean
    field :starts_on_day, :integer
    field :latest_closed_on_day, :integer
  end
end
