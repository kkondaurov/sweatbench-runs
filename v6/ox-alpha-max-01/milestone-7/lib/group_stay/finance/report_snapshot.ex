defmodule GroupStay.Finance.ReportSnapshot do
  @moduledoc """
  The published, byte-for-byte stable rendering of one closed day's report.

  Written once when a close publishes the day; the endpoint serves the
  stored JSON verbatim, so later operations, later closes, and process
  restarts can never move a single figure of an already-signed-off day.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_report_snapshots" do
    field :report_date, :date
    field :data_json, :string

    timestamps()
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:report_date, :data_json])
    |> validate_required([:report_date, :data_json])
    |> unique_constraint(:report_date)
  end
end
