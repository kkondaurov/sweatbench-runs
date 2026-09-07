defmodule GroupStay.Finance.Reporting.PeriodClose do
  @moduledoc """
  A durable publication boundary committed with its partner operation.

  Cutoffs strictly increase. Once published, journal entries through a cutoff
  never change and no new entries can be posted there. This preserves even days
  that have never been read, without materializing a snapshot for every date.
  """

  use Ecto.Schema

  schema "finance_period_closes" do
    field :operation_id, :string
    field :period_end_on, :date
  end
end
