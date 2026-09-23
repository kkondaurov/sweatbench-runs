defmodule GroupStay.FinanceReports.PeriodClose do
  @moduledoc """
  A closed finance period: reports through `period_end_on` are published and no later operation
  posts on or before it. Each close's cutoff is later than every earlier close's.
  """
  use Ecto.Schema

  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "finance_period_closes" do
    field :period_end_on, :date
    field :operation_id, :string

    timestamps()
  end
end
