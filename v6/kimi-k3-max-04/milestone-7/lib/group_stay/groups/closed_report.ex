defmodule GroupStay.Groups.ClosedReport do
  @moduledoc """
  The published finance report for one closed date. A `close_finance_period`
  operation materializes `data` for every report date through its cutoff, so
  the value delivered from then on is byte-for-byte stable across later
  operations, later closes, and process restarts. The date is the primary
  key; closes are strictly increasing, so a date is frozen at most once.
  """

  use Ecto.Schema

  @primary_key {:date, :date, autogenerate: false}
  schema "closed_reports" do
    field :data, :map

    timestamps()
  end
end
