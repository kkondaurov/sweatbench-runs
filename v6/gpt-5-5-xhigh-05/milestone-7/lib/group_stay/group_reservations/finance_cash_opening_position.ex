defmodule GroupStay.GroupReservations.FinanceCashOpeningPosition do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.GroupReservations.FinanceReportingStart

  schema "finance_cash_opening_positions" do
    field :property_id, :string
    field :opening_held_cents, :integer, default: 0

    belongs_to :finance_reporting_start, FinanceReportingStart

    timestamps(type: :utc_datetime)
  end

  def changeset(position, attrs) do
    position
    |> cast(attrs, [:finance_reporting_start_id, :property_id, :opening_held_cents])
    |> validate_required([:finance_reporting_start_id, :property_id, :opening_held_cents])
    |> validate_number(:opening_held_cents, greater_than: 0)
  end
end
