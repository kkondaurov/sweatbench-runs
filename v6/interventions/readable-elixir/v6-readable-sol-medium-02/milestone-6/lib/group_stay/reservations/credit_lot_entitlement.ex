defmodule GroupStay.Reservations.CreditLotEntitlement do
  @moduledoc "The bonus-bearing share of a credit lot attributable to one cash payment."

  use Ecto.Schema

  alias GroupStay.Reservations.{CashPaymentAccounting, HotelCreditLot}

  schema "credit_lot_entitlements" do
    field :principal_cents, :integer
    field :entitlement_cents, :integer
    belongs_to :lot, HotelCreditLot
    belongs_to :payment_accounting, CashPaymentAccounting
    timestamps(type: :utc_datetime)
  end
end
