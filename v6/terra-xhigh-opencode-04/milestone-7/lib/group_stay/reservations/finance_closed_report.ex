defmodule GroupStay.Reservations.FinanceClosedReport do
  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_closed_reports" do
    field :report_date, :date
    field :data, :map

    belongs_to :finance_reporting, GroupStay.Reservations.FinanceReporting
  end

  def changeset(report, attrs) do
    report
    |> cast(attrs, [:finance_reporting_id, :report_date, :data])
    |> validate_required([:finance_reporting_id, :report_date, :data])
    |> unique_constraint(:report_date,
      name: :finance_closed_reports_finance_reporting_id_report_date_index
    )
  end
end
