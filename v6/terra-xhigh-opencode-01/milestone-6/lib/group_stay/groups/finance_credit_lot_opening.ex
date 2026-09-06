defmodule GroupStay.Groups.FinanceCreditLotOpening do
  use Ecto.Schema

  schema "finance_credit_lot_openings" do
    field :opening_available_cents, :integer

    belongs_to :finance_reporting, GroupStay.Groups.FinanceReporting
    belongs_to :hotel_credit_lot, GroupStay.Groups.HotelCreditLot
  end
end
