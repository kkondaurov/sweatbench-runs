defmodule GroupStay.FinanceReportSnapshot do
  @moduledoc "The immutable published data for one closed daily finance report."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:report_date, :date, autogenerate: false}
  schema "finance_report_snapshots" do
    field :close_period_end_on, :date
    field :data_json, :string
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:report_date, :close_period_end_on, :data_json])
    |> validate_required([:report_date, :close_period_end_on, :data_json])
    |> unique_constraint(:report_date)
  end
end
