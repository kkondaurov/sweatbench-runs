defmodule GroupStay.FinanceReportingCashOpening do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.FinanceReportingStart

  schema "finance_reporting_cash_openings" do
    field :property_id, :string
    field :opening_held_cents, :integer

    belongs_to :reporting_start, FinanceReportingStart
  end

  def changeset(opening, attrs) do
    opening
    |> cast(attrs, [:reporting_start_id, :property_id, :opening_held_cents])
    |> validate_required([:reporting_start_id, :property_id, :opening_held_cents])
    |> validate_number(:opening_held_cents, greater_than_or_equal_to: 0)
    |> unique_constraint([:reporting_start_id, :property_id])
  end
end
