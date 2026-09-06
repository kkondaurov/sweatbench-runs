defmodule GroupStay.FinanceReportingStart do
  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_reporting_starts" do
    field :singleton, :boolean, default: true
    field :starts_on, :date
    field :source_operation_id, :string
  end

  def changeset(start, attrs) do
    start
    |> cast(attrs, [:singleton, :starts_on, :source_operation_id])
    |> validate_required([:singleton, :starts_on, :source_operation_id])
    |> unique_constraint(:singleton)
  end
end
