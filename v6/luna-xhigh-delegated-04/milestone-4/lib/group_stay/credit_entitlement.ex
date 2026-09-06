defmodule GroupStay.CreditEntitlement do
  use Ecto.Schema

  schema "hotel_credit_entitlements" do
    field :credit_lot_id, :integer
    field :payment_operation_id, :string
    field :cash_amount_cents, :integer
    field :credit_amount_cents, :integer
  end
end
