defmodule GroupStay.Groups.FinanceClosedReport do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "finance_closed_reports" do
    field :report_date, :date
    field :data_json, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(report, attrs) do
    report
    |> cast(attrs, [:report_date, :data_json])
    |> validate_required([:report_date, :data_json])
    |> unique_constraint(:report_date)
  end
end
