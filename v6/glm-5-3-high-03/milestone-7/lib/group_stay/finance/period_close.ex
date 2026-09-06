defmodule GroupStay.Finance.PeriodClose do
  @moduledoc """
  The durable record of one successful finance period close: the operation
  that committed it and the cutoff date it closed through.

  Closes are applied strictly later than the latest recorded cutoff, so the
  newest row always carries the latest one. Together with
  `GroupStay.Finance.ReportSnapshot` rows created by the same close, it fixes
  every daily report through the cutoff as published.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "finance_period_closes" do
    field :operation_id, :string
    field :period_end_on, :date

    timestamps(type: :utc_datetime)
  end
end
