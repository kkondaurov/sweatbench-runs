defmodule GroupStay.Groups.FinancePeriodClose do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "finance_period_closes" do
    field :operation_id, :string
    field :period_end_on, :date

    timestamps(type: :utc_datetime)
  end

  def changeset(close, attrs) do
    close
    |> cast(attrs, [:operation_id, :period_end_on])
    |> validate_required([:operation_id, :period_end_on])
    |> unique_constraint(:operation_id)
    |> unique_constraint(:period_end_on)
  end
end
