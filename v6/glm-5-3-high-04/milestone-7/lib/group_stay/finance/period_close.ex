defmodule GroupStay.Finance.PeriodClose do
  @moduledoc """
  One successful `close_finance_period` operation.

  Each close publishes every daily report through its `period_end_on`. A
  later close must be strictly later than the latest recorded close, so
  `period_end_on` increases and the latest row is always the current
  reporting cutoff.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "finance_period_closes" do
    field :period_end_on, :date
    field :operation_id, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(close, attrs) do
    close
    |> Ecto.Changeset.cast(attrs, [:period_end_on, :operation_id])
    |> Ecto.Changeset.validate_required([:period_end_on, :operation_id])
  end
end
