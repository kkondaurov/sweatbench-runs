defmodule GroupStay.FinanceReportPublication do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:report_date, :date, autogenerate: false}
  schema "finance_report_publications" do
    field :data, :map
  end

  def changeset(publication, attrs) do
    cast(publication, attrs, [:report_date, :data])
    |> validate_required([:report_date, :data])
  end
end
