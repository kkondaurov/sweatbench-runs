defmodule GroupStay.Groups.PaymentCreditEntitlement do
  use Ecto.Schema

  schema "payment_credit_entitlements" do
    field :credit_cents, :integer

    belongs_to :cash_payment_source, GroupStay.Groups.CashPaymentSource
    belongs_to :hotel_credit_lot, GroupStay.Groups.HotelCreditLot
  end
end
