defmodule GroupStay.Finance.PeriodClose do
  @moduledoc """
  One successful close of the finance period. Each applied
  `close_finance_period` operation appends a row; the cutoff only ever moves
  forward, so the latest successful close carries the greatest
  `period_end_on`. Reports through that cutoff are published and later
  operations post their finance effects on the first open day.
  """

  use Ecto.Schema

  schema "finance_period_closes" do
    field :operation_id, :string
    field :period_end_on, :date

    timestamps(type: :utc_datetime)
  end
end
