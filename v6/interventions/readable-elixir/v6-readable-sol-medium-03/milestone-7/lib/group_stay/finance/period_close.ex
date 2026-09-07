defmodule GroupStay.Finance.PeriodClose do
  @moduledoc """
  A durable finance publication cutoff.

  Close rows are append-only. The greatest cutoff defines the first currently open reporting day,
  while report snapshots preserve the figures published by every successful close.
  """

  use Ecto.Schema

  schema "finance_period_closes" do
    field :period_end_on, :date
    timestamps(type: :utc_datetime)
  end
end
