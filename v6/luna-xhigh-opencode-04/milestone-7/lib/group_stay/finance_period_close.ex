defmodule GroupStay.FinancePeriodClose do
  use Ecto.Schema

  schema "finance_period_closes" do
    field :operation_id, :string
    field :period_end_on, :date
  end
end
