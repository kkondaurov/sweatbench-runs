defmodule GroupStay.FinanceReport do
  use Ecto.Schema

  schema "finance_reports" do
    field :report_date, :date
    field :report_json, :string
    field :status, :string
  end
end
