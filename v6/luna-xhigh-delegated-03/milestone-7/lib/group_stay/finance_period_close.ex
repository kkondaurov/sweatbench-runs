defmodule GroupStay.FinancePeriodClose do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  schema "finance_period_closes" do
    field :period_end_on, :date
  end
end
