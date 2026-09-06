defmodule GroupStay.FinanceOpeningCredit do
  use Ecto.Schema

  @primary_key {:credit_lot_id, :integer, autogenerate: false}

  schema "finance_opening_credit" do
    field :available_cents, :integer
    field :liability_cents, :integer
    field :expires_on, :date
  end
end
