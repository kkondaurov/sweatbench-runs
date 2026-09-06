defmodule GroupStay.FinanceReportingCashOpening do
  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_reporting_cash_openings" do
    field :property_id, :string
    field :opening_held_cents, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(opening, attrs) do
    opening
    |> cast(attrs, [:property_id, :opening_held_cents])
    |> validate_required([:property_id, :opening_held_cents])
    |> unique_constraint(:property_id)
  end
end
