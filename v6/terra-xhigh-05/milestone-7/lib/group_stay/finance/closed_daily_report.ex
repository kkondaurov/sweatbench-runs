defmodule GroupStay.Finance.ClosedDailyReport do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime]

  schema "finance_reporting_closed_daily_reports" do
    field :report_on, :date
    field :report_data, :map

    timestamps()
  end

  def changeset(report, attrs) do
    report
    |> cast(attrs, [:report_on, :report_data])
    |> validate_required([:report_on, :report_data])
    |> unique_constraint(:report_on)
  end
end
