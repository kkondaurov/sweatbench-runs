defmodule GroupStay.FinanceReport do
  use Ecto.Schema

  @primary_key {:date, :date, autogenerate: false}
  schema "finance_reports" do
    field :data, :map
  end
end
