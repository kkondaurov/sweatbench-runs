defmodule GroupStay.Reservations.GroupCreditPayment do
  use Ecto.Schema

  schema "group_credit_payments" do
    field :amount_cents, :integer

    belongs_to :group_reservation, GroupStay.Reservations.GroupReservation
    belongs_to :hotel_credit_lot, GroupStay.Reservations.HotelCreditLot

    timestamps(type: :utc_datetime)
  end
end
