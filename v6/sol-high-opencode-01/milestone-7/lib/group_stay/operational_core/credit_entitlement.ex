defmodule GroupStay.OperationalCore.CreditEntitlement do
  use Ecto.Schema

  schema "credit_entitlements" do
    field :source_operation_id, :string
    field :payment_operation_id, :string
    field :amount_cents, :integer
  end
end
