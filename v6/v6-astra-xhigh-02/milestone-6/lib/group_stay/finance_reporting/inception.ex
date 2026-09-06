defmodule GroupStay.FinanceReporting.Inception do
  @moduledoc false
  use Ecto.Schema

  schema "finance_reporting" do
    field :starts_on, :date
    field :opening, :map
  end
end
