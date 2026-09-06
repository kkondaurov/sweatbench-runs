defmodule GroupStay.FinanceReporting.Snapshot do
  @moduledoc """
  The published copy of one daily report.

  When a finance period close is processed, the report of every date through
  the close cutoff is frozen and stored here as its JSON `data` value. A
  frozen report is returned byte-for-byte unchanged on every later read, no
  matter which operations or closes follow.
  """

  use Ecto.Schema

  schema "finance_report_snapshots" do
    field :report_date, :date
    field :data, :string
  end
end
