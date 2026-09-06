defmodule GroupStay.FinanceReportingCreditOpening do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.FinanceReportingStart

  schema "finance_reporting_credit_openings" do
    field :credit_lot_id, :integer
    field :available_cents, :integer
    field :applied_cents, :integer
    field :expires_on, :date

    belongs_to :reporting_start, FinanceReportingStart
  end

  def changeset(opening, attrs) do
    opening
    |> cast(attrs, [
      :reporting_start_id,
      :credit_lot_id,
      :available_cents,
      :applied_cents,
      :expires_on
    ])
    |> validate_required([
      :reporting_start_id,
      :credit_lot_id,
      :available_cents,
      :applied_cents,
      :expires_on
    ])
    |> validate_number(:available_cents, greater_than_or_equal_to: 0)
    |> validate_number(:applied_cents, greater_than_or_equal_to: 0)
    |> unique_constraint([:reporting_start_id, :credit_lot_id])
  end
end
