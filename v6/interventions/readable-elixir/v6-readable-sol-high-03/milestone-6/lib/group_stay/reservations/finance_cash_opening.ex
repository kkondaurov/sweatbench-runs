defmodule GroupStay.Reservations.FinanceCashOpening do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Reservations.FinanceReportingPeriod

  schema "finance_cash_openings" do
    belongs_to :reporting_period, FinanceReportingPeriod
    field :property_id, :string
    field :held_cents, :integer
  end

  def changeset(opening, attributes) do
    opening
    |> cast(attributes, [:reporting_period_id, :property_id, :held_cents])
    |> validate_required([:reporting_period_id, :property_id, :held_cents])
    |> validate_number(:held_cents, greater_than: 0)
    |> unique_constraint([:reporting_period_id, :property_id])
  end
end
