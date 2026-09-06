defmodule GroupStay.Reservations.FinanceCashOpeningPosition do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_cash_opening_positions" do
    field :property_id, :string
    field :amount_cents, :integer

    belongs_to :finance_reporting_start, GroupStay.Reservations.FinanceReportingStart

    timestamps(type: :utc_datetime)
  end

  def changeset(cash_opening_position, attrs) do
    cash_opening_position
    |> cast(attrs, [:finance_reporting_start_id, :property_id, :amount_cents])
    |> validate_required([:finance_reporting_start_id, :property_id, :amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
    |> unique_constraint([:finance_reporting_start_id, :property_id])
  end
end
