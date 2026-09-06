defmodule GroupStay.Finance.PeriodClose do
  @moduledoc """
  One durable close of the finance reporting period.

  A close publishes every daily report through `period_end_on`; from then on
  those reports are immutable. Successful closes move strictly forward, so
  the latest close's `period_end_on` is the current reporting cutoff.
  """

  use Ecto.Schema

  schema "finance_period_closes" do
    field :operation_id, :string
    field :period_end_on, :date

    timestamps()
  end
end
