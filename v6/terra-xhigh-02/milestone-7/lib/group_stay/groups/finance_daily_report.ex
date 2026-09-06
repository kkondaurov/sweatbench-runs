defmodule GroupStay.Groups.FinanceDailyReport do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.FinanceReportingStart

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "finance_daily_reports" do
    belongs_to :reporting_start, FinanceReportingStart, type: :id
    field :report_date, :date
    field :data_json, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(report, attrs) do
    report
    |> cast(attrs, [:reporting_start_id, :report_date, :data_json])
    |> validate_required([:reporting_start_id, :report_date, :data_json])
    |> unique_constraint([:reporting_start_id, :report_date])
  end
end
