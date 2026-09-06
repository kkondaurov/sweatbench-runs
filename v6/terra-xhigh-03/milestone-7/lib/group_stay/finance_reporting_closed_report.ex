defmodule GroupStay.FinanceReportingClosedReport do
  @moduledoc """
  The immutable published data for one closed finance-reporting day.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_reporting_closed_reports" do
    field :report_date, :date
    field :data, :map

    timestamps(type: :utc_datetime)
  end

  def changeset(report, attrs) do
    report
    |> cast(attrs, [:report_date, :data])
    |> validate_required([:report_date, :data])
    |> unique_constraint(:report_date)
  end
end
