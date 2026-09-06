defmodule GroupStay.Reservations.CreditLotCashEntitlement do
  use Ecto.Schema

  alias GroupStay.Reservations.{CashFunding, CreditLot}

  schema "credit_lot_cash_entitlements" do
    field :principal_cents, :integer, default: 0
    field :entitlement_cents, :integer, default: 0

    belongs_to :credit_lot, CreditLot
    belongs_to :cash_funding, CashFunding

    timestamps(type: :utc_datetime)
  end
end
