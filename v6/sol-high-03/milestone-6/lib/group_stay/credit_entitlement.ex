defmodule GroupStay.CreditEntitlement do
  use Ecto.Schema

  alias GroupStay.CreditLot

  schema "credit_entitlements" do
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :revoked, :boolean, default: false
    belongs_to :credit_lot, CreditLot
  end
end
