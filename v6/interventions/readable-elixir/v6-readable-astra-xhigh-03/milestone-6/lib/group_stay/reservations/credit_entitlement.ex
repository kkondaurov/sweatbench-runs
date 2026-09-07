defmodule GroupStay.Reservations.CreditEntitlement do
  @moduledoc """
  The fixed credit entitlement created by a payment's contribution to one lot.

  Entitlements are differences of rounded running totals in funding order. They
  exactly partition the issued lot, including its bonus. Redemption remains
  fungible: it is attributed to the lot, never to these payment entitlements.
  """
  use Ecto.Schema

  schema "credit_entitlements" do
    field :credit_lot_id, :id
    field :payment_operation_id, :string
    field :amount_cents, :integer
  end
end
