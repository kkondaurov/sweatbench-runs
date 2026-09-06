defmodule GroupStay.Reporting.FinancePeriodClose do
  @moduledoc """
  One successful `close_finance_period` operation. Every daily report
  through the latest `period_end_on` is published: it returns
  `status: "closed"` and never moves again, while operations processed
  after the close post on the first open day.
  """

  use Ecto.Schema

  schema "finance_period_closes" do
    field :period_end_on, :date

    timestamps(type: :utc_datetime_usec)
  end
end
