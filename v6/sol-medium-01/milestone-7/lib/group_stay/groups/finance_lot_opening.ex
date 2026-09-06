defmodule GroupStay.Groups.FinanceLotOpening do
  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_lot_openings" do
    field :available_cents, :integer
    belongs_to :finance_reporting, GroupStay.Groups.FinanceReporting
    belongs_to :credit_lot, GroupStay.Groups.CreditLot

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(opening, attrs) do
    opening
    |> cast(attrs, [:finance_reporting_id, :credit_lot_id, :available_cents])
    |> validate_required([:finance_reporting_id, :credit_lot_id, :available_cents])
  end
end
