defmodule GroupStay.FinanceReporting.Inception do
  @moduledoc "The singleton opening position captured when controllers enable reporting."
  use Ecto.Schema

  schema "finance_reporting" do
    field :starts_on, :date
    field :opening_cash, :map
    field :opening_credit_cents, :integer
  end
end
