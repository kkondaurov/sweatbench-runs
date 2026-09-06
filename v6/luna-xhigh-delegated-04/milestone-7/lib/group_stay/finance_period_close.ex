defmodule GroupStay.FinancePeriodClose do
  use Ecto.Schema

  schema "finance_period_closes" do
    field :period_end_on, :date
  end
end
