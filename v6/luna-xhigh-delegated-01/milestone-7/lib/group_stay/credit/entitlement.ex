defmodule GroupStay.Credit.Entitlement do
  use Ecto.Schema

  schema "hotel_credit_entitlements" do
    field :lot_id, :integer
    field :payment_operation_id, :string
    field :amount_cents, :integer
  end
end
