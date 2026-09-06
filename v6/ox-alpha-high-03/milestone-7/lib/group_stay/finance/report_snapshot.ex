defmodule GroupStay.Finance.ReportSnapshot do
  @moduledoc """
  The published daily report for one closed reporting date.

  Snapshotted when a period close covers the date; reads of a closed date
  return this stored data verbatim so later operations, later closes, and
  process restarts never rewrite it.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "finance_report_snapshots" do
    field :report_date, :date
    field :data, :string

    timestamps(type: :utc_datetime)
  end
end
