defmodule GroupStay.Finance.ClosedReport do
  @moduledoc """
  The published snapshot of one closed daily report.

  When a period close is processed, every report from `starts_on` through the
  cutoff that is not already closed is built and stored here. Closed days are
  served from their snapshot, so the report's `data` value remains
  byte-for-byte stable across later operations, later closes, and process
  restarts.
  """

  use Ecto.Schema

  @primary_key {:date, :date, autogenerate: false}

  schema "finance_closed_reports" do
    field :data, :string

    timestamps(type: :utc_datetime)
  end
end
