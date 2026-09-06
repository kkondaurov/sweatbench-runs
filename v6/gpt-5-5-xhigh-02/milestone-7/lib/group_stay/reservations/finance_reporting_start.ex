defmodule GroupStay.Reservations.FinanceReportingStart do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}
  schema "finance_reporting_starts" do
    field :operation_id, :string
    field :starts_on, :date
    field :opening_cash_by_property, :map, default: %{}
    field :opening_credit_liability_cents, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(
    id
    operation_id
    starts_on
    opening_cash_by_property
    opening_credit_liability_cents
  )a

  def changeset(reporting_start, attrs) do
    reporting_start
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> validate_number(:id, equal_to: 1)
    |> validate_number(:opening_credit_liability_cents, greater_than_or_equal_to: 0)
    |> unique_constraint(:operation_id)
  end
end
