defmodule GroupStay.Bookings.FinanceCreditExpiry do
  use Ecto.Schema

  alias GroupStay.Bookings.CreditLot

  schema "finance_credit_expiries" do
    field :posting_on, :date
    field :late_adjustment, :boolean, default: false
    field :amount_cents, :integer
    belongs_to :credit_lot, CreditLot
  end
end
