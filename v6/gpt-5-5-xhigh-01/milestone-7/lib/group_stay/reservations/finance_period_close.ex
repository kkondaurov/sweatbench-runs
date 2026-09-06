defmodule GroupStay.Reservations.FinancePeriodClose do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_period_closes" do
    field :operation_id, :string
    field :period_end_on, :date

    timestamps(type: :utc_datetime)
  end

  def changeset(period_close, attrs) do
    period_close
    |> cast(attrs, [:operation_id, :period_end_on])
    |> validate_required([:operation_id, :period_end_on])
    |> unique_constraint(:operation_id)
    |> unique_constraint(:period_end_on)
  end
end
