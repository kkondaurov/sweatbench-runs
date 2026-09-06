defmodule GroupStay.Reservations.FinancePeriodClose do
  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_period_closes" do
    field :operation_id, :string
    field :period_end_on, :date

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(operation_id period_end_on)a

  def changeset(period_close, attrs) do
    period_close
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:operation_id)
  end
end
