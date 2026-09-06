defmodule GroupStay.Finance.ReportSnapshot do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "finance_report_snapshots" do
    field :report_date, :date
    field :data_json, :string
  end

  def changeset(snapshot, attrs) do
    Ecto.Changeset.cast(snapshot, attrs, [:report_date, :data_json])
    |> Ecto.Changeset.validate_required([:report_date, :data_json])
  end
end
