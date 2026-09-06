defmodule GroupStay.FinanceReportSnapshot do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "finance_report_snapshots" do
    field :report_date, :date
    field :data, :map

    timestamps()
  end
end
