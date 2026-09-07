defmodule GroupStay.FinanceReporting.Inception do
  @moduledoc "The singleton reporting opening position and monotonically advancing published cutoff."
  use Ecto.Schema

  schema "finance_reporting" do
    field :starts_on, :date
    field :closed_through, :date
    field :opening_cash, :map
    field :opening_credit_cents, :integer
  end
end
