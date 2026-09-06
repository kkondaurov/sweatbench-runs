defmodule GroupStay.Finance.ClosedReport do
  @moduledoc """
  The published, immutable report for one closed reporting day.

  When a period is closed, every day through the cutoff is built once and
  stored here; later reads return the stored data exactly, so closed days
  are byte-for-byte stable across later operations, later closes, and
  process restarts.
  """

  use Ecto.Schema

  schema "finance_closed_reports" do
    field :date, :date
    field :data, :map

    timestamps()
  end
end
