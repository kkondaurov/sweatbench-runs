defmodule GroupStay.FinanceReporting.Inception do
  @moduledoc "The singleton, immutable opening position captured when reporting is enabled."
  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}
  schema "finance_reporting" do
    field :starts_on, :date
    field :opening_cash, :map
    field :opening_credit_cents, :integer
  end
end
