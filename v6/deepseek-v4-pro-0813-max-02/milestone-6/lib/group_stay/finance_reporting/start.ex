defmodule GroupStay.FinanceReporting.Start do
  @moduledoc """
  The single row that records that finance reporting has been enabled and its
  opening position.

  The row exists at most once; the `singleton` column enforces that with a
  unique index. `starts_on` is the first report date and the opening
  liability is the liability at the start of that day.
  """

  use Ecto.Schema

  schema "finance_reporting" do
    field :singleton, :integer, default: 1
    field :starts_on, :date
    field :opening_liability_cents, :integer, default: 0
  end
end
