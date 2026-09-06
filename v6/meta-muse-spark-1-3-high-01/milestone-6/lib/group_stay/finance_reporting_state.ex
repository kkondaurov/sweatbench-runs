defmodule GroupStay.FinanceReportingState do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_reporting_states" do
    field :starts_on, :date
    field :started_by_operation_id, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(state, attrs) do
    state
    |> cast(attrs, [:starts_on, :started_by_operation_id])
    |> validate_required([:starts_on, :started_by_operation_id])
  end
end
