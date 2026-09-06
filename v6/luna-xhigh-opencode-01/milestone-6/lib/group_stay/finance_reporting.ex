defmodule GroupStay.FinanceReporting do
  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}

  schema "finance_reporting" do
    field :starts_on, :date
  end
end
