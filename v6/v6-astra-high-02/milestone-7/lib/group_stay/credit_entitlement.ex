defmodule GroupStay.CreditEntitlement do
  use Ecto.Schema

  schema "credit_entitlements" do
    field :payment_operation_id, :string
    field :credit_lot_id, :id
    field :amount_cents, :integer
  end
end
