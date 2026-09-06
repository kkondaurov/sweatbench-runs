defmodule GroupStay.Groups.FinanceDailyReport do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_daily_reports" do
    field :reporting_id, :integer
    field :report_on, :date
    field :data, :string
  end

  def changeset(report, attrs) do
    cast(report, attrs, [:reporting_id, :report_on, :data])
  end
end
