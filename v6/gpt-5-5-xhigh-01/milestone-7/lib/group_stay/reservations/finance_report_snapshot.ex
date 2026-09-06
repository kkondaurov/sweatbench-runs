defmodule GroupStay.Reservations.FinanceReportSnapshot do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_report_snapshots" do
    field :report_date, :date
    field :data_json, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(report_snapshot, attrs) do
    report_snapshot
    |> cast(attrs, [:report_date, :data_json])
    |> validate_required([:report_date, :data_json])
    |> unique_constraint(:report_date)
  end
end
