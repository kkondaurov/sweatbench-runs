defmodule GroupStay.Finance.PeriodClose do
  @moduledoc """
  One successful `close_finance_period` operation.

  `period_end_on` is the inclusive cutoff through which daily finance reports
  are published. Closes strictly advance, enforced by the unique index and
  the validation in `GroupStay.Finance.Reporting`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "finance_period_closes" do
    field :period_end_on, :date

    timestamps(type: :utc_datetime)
  end
end
