defmodule GroupStay.Reporting.FinanceReportSnapshot do
  use Ecto.Schema

  @primary_key {:report_date, :date, autogenerate: false}

  schema "finance_report_snapshots" do
    field :data_json, :string
  end
end
