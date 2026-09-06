defmodule GroupStay.CreditEntitlement do
  use Ecto.Schema

  schema "credit_entitlements" do
    field :credit_lot_id, :integer
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :revoked_cents, :integer
  end
end
