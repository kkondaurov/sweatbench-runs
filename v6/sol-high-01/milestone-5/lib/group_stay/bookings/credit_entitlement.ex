defmodule GroupStay.Bookings.CreditEntitlement do
  use Ecto.Schema

  alias GroupStay.Bookings.CreditLot

  schema "credit_entitlements" do
    field :payment_operation_id, :string
    field :principal_cents, :integer
    field :entitlement_cents, :integer
    field :revoked_cents, :integer, default: 0

    belongs_to :credit_lot, CreditLot
  end
end
