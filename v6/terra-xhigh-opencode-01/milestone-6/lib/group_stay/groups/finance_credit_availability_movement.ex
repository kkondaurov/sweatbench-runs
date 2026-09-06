defmodule GroupStay.Groups.FinanceCreditAvailabilityMovement do
  use Ecto.Schema

  schema "finance_credit_availability_movements" do
    field :posting_on, :date
    field :amount_cents, :integer

    belongs_to :hotel_credit_lot, GroupStay.Groups.HotelCreditLot
  end
end
