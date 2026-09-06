defmodule GroupStay.Reservations.FinanceReportingStart do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_reporting_starts" do
    field :operation_id, :string
    field :starts_on, :date
    field :opening_credit_liability_cents, :integer
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(start, attrs) do
    start
    |> cast(attrs, [:operation_id, :starts_on, :opening_credit_liability_cents])
    |> validate_required([:operation_id, :starts_on, :opening_credit_liability_cents])
    |> unique_constraint(:operation_id)
  end
end
