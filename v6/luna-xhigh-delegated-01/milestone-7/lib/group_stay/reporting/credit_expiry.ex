defmodule GroupStay.Reporting.CreditExpiry do
  use Ecto.Schema

  schema "finance_credit_expiries" do
    field :lot_id, :integer
    field :expires_on, :date
    field :scheduled_cents, :integer, default: 0
  end
end
