defmodule GroupStay.FinanceReporting.PeriodClose do
  @moduledoc """
  A published reporting cutoff, committed atomically with its partner operation.

  Cutoffs advance strictly under the operation's write lock. Journal entries are
  immutable, and subsequent entries must post after the latest cutoff, so published
  reports can be reproduced without storing a separate snapshot for every day.
  """
  use Ecto.Schema

  schema "finance_period_closes" do
    field :operation_id, :string
    field :period_end_on, :date
  end
end
