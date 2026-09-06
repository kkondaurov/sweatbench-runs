defmodule GroupStay.FinanceReporting.Close do
  @moduledoc """
  One applied finance period close.

  `period_end_on` is the last report date of the closed period. Closes must
  arrive in strictly increasing cutoff order, and the unique index on
  `period_end_on` enforces that at the database level.
  """

  use Ecto.Schema

  schema "finance_period_closes" do
    field :period_end_on, :date

    timestamps()
  end
end
