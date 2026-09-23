defmodule GroupStay.FinanceReports.ReportingStart do
  @moduledoc """
  The start of daily finance reporting: the first report date and the operation that started it.
  There is at most one.
  """
  use Ecto.Schema

  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "finance_reporting" do
    field :starts_on, :date
    field :operation_id, :string

    timestamps()
  end
end
