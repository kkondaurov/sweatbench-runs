defmodule GroupStay.Schemas.FinanceReportingState do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "finance_reporting_states" do
    field :singleton, :integer
    field :starts_on, :date
    field :started_by_operation_id, :string
    field :opening_credit_liability_cents, :integer

    timestamps()
  end
end
