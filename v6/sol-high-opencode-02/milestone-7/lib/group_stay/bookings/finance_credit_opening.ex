defmodule GroupStay.Bookings.FinanceCreditOpening do
  use Ecto.Schema

  schema "finance_credit_openings" do
    field :credit_lot_id, :integer
    field :available_cents, :integer
    field :expires_on, :date
  end
end
