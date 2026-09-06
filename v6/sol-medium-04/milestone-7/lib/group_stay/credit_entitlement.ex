defmodule GroupStay.CreditEntitlement do
  use Ecto.Schema

  schema "credit_entitlements" do
    field :amount_cents, :integer
    belongs_to :credit_lot, GroupStay.CreditLot
    belongs_to :payment_account, GroupStay.PaymentAccount

    timestamps(type: :utc_datetime)
  end
end
