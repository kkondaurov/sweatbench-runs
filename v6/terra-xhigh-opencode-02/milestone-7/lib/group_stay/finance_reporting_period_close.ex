defmodule GroupStay.FinanceReportingPeriodClose do
  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_reporting_period_closes" do
    field :period_end_on, :date
    field :source_operation_id, :string
  end

  def changeset(close, attrs) do
    close
    |> cast(attrs, [:period_end_on, :source_operation_id])
    |> validate_required([:period_end_on, :source_operation_id])
    |> unique_constraint(:period_end_on)
  end
end
