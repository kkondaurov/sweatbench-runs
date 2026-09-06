defmodule GroupStay.FinanceReporting.Inception do
  use Ecto.Schema

  schema "finance_reporting" do
    field :starts_on, :date
  end
end
