defmodule GroupStay.Finance.CreditExpiration do
  use Ecto.Schema

  @primary_key {:credit_lot_id, :binary_id, autogenerate: false}

  schema "finance_credit_expirations" do
    field :expires_on, :date
    field :amount_cents, :integer
  end
end
