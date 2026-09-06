defmodule GroupStay.Reservations.HotelCreditApplication do
  use Ecto.Schema

  alias GroupStay.Reservations.{CreditLot, Group}

  schema "group_credit_applications" do
    field :amount_cents, :integer

    belongs_to :group, Group
    belongs_to :credit_lot, CreditLot

    timestamps(type: :utc_datetime)
  end
end
