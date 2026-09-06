defmodule GroupStay.FinancePeriodClose do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_period_closes" do
    field :period_end_on, :date
    field :closed_by_operation_id, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(close, attrs) do
    close
    |> cast(attrs, [:period_end_on, :closed_by_operation_id])
    |> validate_required([:period_end_on, :closed_by_operation_id])
    |> unique_constraint(:period_end_on)
  end
end
