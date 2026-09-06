defmodule GroupStay.Groups.FinanceReportingStart do
  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_reporting_starts" do
    field :singleton, :integer, default: 1
    field :starts_on, :date
    field :opening_credit_liability_cents, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(start, attrs) do
    start
    |> cast(attrs, [:singleton, :starts_on, :opening_credit_liability_cents])
    |> validate_required([:singleton, :starts_on, :opening_credit_liability_cents])
    |> validate_inclusion(:singleton, [1])
    |> validate_number(:opening_credit_liability_cents, greater_than_or_equal_to: 0)
    |> unique_constraint(:singleton)
  end
end
