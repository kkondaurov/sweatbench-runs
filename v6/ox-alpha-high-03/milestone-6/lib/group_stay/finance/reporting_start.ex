defmodule GroupStay.Finance.ReportingStart do
  @moduledoc """
  The durable inception point of finance reporting.

  There is at most one row: the first applied `start_finance_reporting`
  operation inserts it. `starts_on` is the partner-supplied opening date and
  `captured_on` is the date on which the opening position was captured, so
  credit that already expired before capture is never reported as expiring
  again.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "finance_reporting_starts" do
    field :starts_on, :date
    field :captured_on, :date

    timestamps(type: :utc_datetime)
  end
end
