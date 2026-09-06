defmodule GroupStay.Finance.PeriodClose do
  @moduledoc """
  One cutoff a controller has signed off.

  Every report through `period_end_on` is published from the moment the close commits and never
  moves again, so closes only ever go forward: a close is applied only when its cutoff is strictly
  later than every cutoff already recorded. `operation_id` names the operation that closed the
  period, which is also the operation a retry is answered from.
  """

  use Ecto.Schema

  schema "finance_period_closes" do
    field :period_end_on, :date
    field :operation_id, :string

    timestamps(type: :utc_datetime)
  end
end
