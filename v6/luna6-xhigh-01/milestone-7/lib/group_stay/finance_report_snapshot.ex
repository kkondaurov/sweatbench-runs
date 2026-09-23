defmodule GroupStay.FinanceReportSnapshot do
  use Ecto.Schema

  @primary_key {:date, :date, autogenerate: false}
  schema "finance_report_snapshots" do
    field :data, :map
  end
end
