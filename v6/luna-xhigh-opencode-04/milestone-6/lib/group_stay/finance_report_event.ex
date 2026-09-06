defmodule GroupStay.FinanceReportEvent do
  use Ecto.Schema

  schema "finance_report_events" do
    field :operation_id, :string
    field :posting_on, :date
    field :cash_movements, :map
    field :credit_movements, :map
    field :credit_lot_changes, :map
  end
end
