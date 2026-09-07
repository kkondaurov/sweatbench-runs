defmodule GroupStay.Finance.ReportSnapshot do
  @moduledoc """
  The exact `data` value published for a closed daily finance report.

  Reports are materialized during the close transaction so later accounting corrections and
  process restarts cannot revise an already published day.
  """

  use Ecto.Schema

  schema "finance_report_snapshots" do
    field :report_on, :date
    field :data, :map
    timestamps(type: :utc_datetime)
  end
end
