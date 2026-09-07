defmodule GroupStay.HotelCredit.Entitlement do
  @moduledoc """
  The bonus-inclusive credit created by one payment in one cancellation lot.
  Entitlements are fixed at issuance; spending within the lot remains fungible.
  """
  use Ecto.Schema

  schema "credit_entitlements" do
    belongs_to :cash_payment, GroupStay.Accounting.CashPayment
    belongs_to :credit_lot, GroupStay.HotelCredit.Lot
    field :amount_cents, :integer
  end
end
