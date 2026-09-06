defmodule GroupStay.Reporting.FinanceReporting do
  @moduledoc """
  The durable reporting inception point, created by the first applied
  `start_finance_reporting` operation.

  `starts_on` anchors the daily report calendar; the financial state
  immediately before that operation was processed became the opening
  position on that date, captured in the opening balance tables and in
  `opening_credit_liability_cents` (the credit liability as of `starts_on`,
  so credit already expired by then never enters the reports).
  """

  use Ecto.Schema

  schema "finance_reporting" do
    # Pinned to 1 and protected by a unique index: reporting starts once.
    field :singleton, :integer, default: 1
    field :starts_on, :date
    field :opening_credit_liability_cents, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end
end
