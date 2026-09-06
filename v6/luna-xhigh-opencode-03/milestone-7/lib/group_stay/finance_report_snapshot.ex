defmodule GroupStay.FinanceReportSnapshot do
  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_report_snapshots" do
    field :report_on, :date
    field :data_json, :string
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:report_on, :data_json])
    |> validate_required([:report_on, :data_json])
    |> unique_constraint(:report_on)
  end
end
