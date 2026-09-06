defmodule GroupStay.Groups.FinancePeriodClose do
  @moduledoc """
  The durable record of one applied `close_finance_period` operation.

  Every daily report through the latest recorded `period_end_on` is published:
  it reports `status: "closed"` and its data never changes again, because
  operations committing after the close post on the first open day instead.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "finance_period_closes" do
    field :period_end_on, :date

    timestamps(type: :utc_datetime)
  end
end
