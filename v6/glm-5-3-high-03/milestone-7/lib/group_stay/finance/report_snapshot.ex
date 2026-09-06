defmodule GroupStay.Finance.ReportSnapshot do
  @moduledoc """
  The published daily finance report of one date, frozen by the finance
  period close that covered it.

  The stored `data` is the complete report value — including its `"closed"`
  status and its `late_adjustments` block — observed when the close was
  processed. Later operations never rewrite a closed day, so reading a date
  within a closed period returns this data byte for byte unchanged, across
  later operations, later closes, and process restarts.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "finance_report_snapshots" do
    field :date, :date
    field :data, :map

    timestamps(type: :utc_datetime)
  end
end
