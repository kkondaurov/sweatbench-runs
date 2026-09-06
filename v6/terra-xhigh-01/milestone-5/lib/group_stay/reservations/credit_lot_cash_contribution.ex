defmodule GroupStay.Reservations.CreditLotCashContribution do
  @moduledoc false

  use Ecto.Schema

  schema "credit_lot_cash_contributions" do
    field :amount_cents, :integer
    field :funding_position, :integer

    belongs_to :hotel_credit_lot, GroupStay.Reservations.HotelCreditLot
    belongs_to :cash_payment, GroupStay.Reservations.CashPayment

    timestamps(type: :utc_datetime)
  end
end
