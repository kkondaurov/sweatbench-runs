defmodule GroupStay.Finance.Close do
  @moduledoc """
  One successful close of the finance period.

  A close publishes every daily report through `period_end_on`. Cutoffs are
  strictly increasing: a close applies only when reporting has started,
  `period_end_on` is on or after `starts_on`, and it is strictly later than
  the latest successful close.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "finance_period_closes" do
    field :operation_id, :string
    field :period_end_on, :date

    timestamps(type: :utc_datetime)
  end
end
