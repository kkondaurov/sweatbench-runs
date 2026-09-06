defmodule GroupStay.Finance.PeriodClose do
  @moduledoc false

  use Ecto.Schema

  schema "finance_period_closes" do
    field :operation_id, :string
    field :period_end_on, :date

    timestamps()
  end
end
