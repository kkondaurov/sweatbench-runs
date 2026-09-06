defmodule GroupStay.FinanceReport do
  use Ecto.Schema

  @primary_key {:report_date, :date, autogenerate: false}

  schema "finance_reports" do
    field :data, :map
  end
end
