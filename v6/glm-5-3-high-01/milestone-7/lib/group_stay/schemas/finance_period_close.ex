defmodule GroupStay.Schemas.FinancePeriodClose do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "finance_period_closes" do
    field :period_end_on, :date
    field :closed_by_operation_id, :string

    timestamps()
  end
end
