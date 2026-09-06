defmodule GroupStay.Groups.FinanceDailyReportSnapshot do
  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_daily_report_snapshots" do
    field :report_on, :date
    field :data, :map
    belongs_to :finance_reporting, GroupStay.Groups.FinanceReporting

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:finance_reporting_id, :report_on, :data])
    |> validate_required([:finance_reporting_id, :report_on, :data])
    |> unique_constraint([:finance_reporting_id, :report_on])
  end
end
