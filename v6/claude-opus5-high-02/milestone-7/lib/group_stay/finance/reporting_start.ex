defmodule GroupStay.Finance.ReportingStart do
  @moduledoc """
  The inception point of finance reporting.

  The first applied `start_finance_reporting` operation writes the only row this table ever holds:
  `starts_on` is the date the opening position is stated on, and every later operation posts its
  finance effects on or after it. `operation_id` names the operation that started reporting, which
  is also the operation a retry is answered from.
  """

  use Ecto.Schema

  schema "finance_reporting_starts" do
    field :starts_on, :date
    field :operation_id, :string

    timestamps(type: :utc_datetime)
  end
end
