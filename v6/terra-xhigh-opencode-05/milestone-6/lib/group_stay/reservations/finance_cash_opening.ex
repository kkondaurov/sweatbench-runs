defmodule GroupStay.Reservations.FinanceCashOpening do
  use Ecto.Schema

  schema "finance_cash_openings" do
    field :reporting_start_id, :integer
    field :property_id, :string
    field :opening_held_cents, :integer

    timestamps()
  end
end
