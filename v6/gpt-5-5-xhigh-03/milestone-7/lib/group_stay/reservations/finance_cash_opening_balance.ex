defmodule GroupStay.Reservations.FinanceCashOpeningBalance do
  use Ecto.Schema

  schema "finance_cash_opening_balances" do
    field :property_id, :string
    field :opening_held_cents, :integer, default: 0

    timestamps(type: :utc_datetime)
  end
end
