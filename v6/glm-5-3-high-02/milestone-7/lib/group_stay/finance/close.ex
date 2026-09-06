defmodule GroupStay.Finance.Close do
  @moduledoc """
  One successful `close_finance_period` operation: the period's cutoff
  date and the operation that committed it. Every daily report through
  `period_end_on` is published — stored byte-for-byte — when the close
  commits, and later operations post their finance effects no earlier
  than the day after the latest cutoff.
  """

  use Ecto.Schema

  schema "finance_period_closes" do
    field :period_end_on, :date
    field :operation_id, :string

    timestamps()
  end
end
