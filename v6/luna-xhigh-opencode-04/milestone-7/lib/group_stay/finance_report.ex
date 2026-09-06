defmodule GroupStay.FinanceReport do
  use Ecto.Schema

  schema "finance_reports" do
    field :report_date, :date
    field :status, :string
    field :data, :map
  end
end
