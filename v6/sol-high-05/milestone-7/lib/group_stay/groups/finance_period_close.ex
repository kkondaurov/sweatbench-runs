defmodule GroupStay.Groups.FinancePeriodClose do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:period_end_on, :date, autogenerate: false}
  schema "finance_period_closes" do
    field :operation_id, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(close, attrs) do
    close
    |> cast(attrs, [:period_end_on, :operation_id])
    |> validate_required([:period_end_on, :operation_id])
    |> unique_constraint(:operation_id)
  end
end
