defmodule GroupStay.Groups.FinanceReportingStart do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "finance_reporting_starts" do
    field :singleton, :integer, default: 1
    field :operation_id, :string
    field :starts_on, :date
    field :as_of_on, :date
    field :opening_liability_cents, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(start, attrs) do
    start
    |> cast(attrs, [
      :singleton,
      :operation_id,
      :starts_on,
      :as_of_on,
      :opening_liability_cents
    ])
    |> validate_required([
      :singleton,
      :operation_id,
      :starts_on,
      :as_of_on,
      :opening_liability_cents
    ])
    |> unique_constraint(:singleton)
    |> unique_constraint(:operation_id)
  end
end
