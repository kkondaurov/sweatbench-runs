defmodule GroupStay.CreditEntitlement do
  use Ecto.Schema

  alias GroupStay.{CashPayment, CreditLot}

  schema "credit_entitlements" do
    field :principal_cents, :integer
    field :entitlement_cents, :integer
    field :revoked_cents, :integer, default: 0
    belongs_to :credit_lot, CreditLot
    belongs_to :cash_payment, CashPayment
    timestamps(type: :utc_datetime)
  end
end
