defmodule GroupStay.FinanceClosedReport do
  use Ecto.Schema

  @primary_key {:date, :date, autogenerate: false}

  schema "finance_closed_reports" do
    field :data, :map
  end
end
