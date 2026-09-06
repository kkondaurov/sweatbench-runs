defmodule GroupStay.Reservations.FinanceReportingCreditOpening do
  @moduledoc false

  use Ecto.Schema

  schema "finance_reporting_credit_openings" do
    field :opening_available_cents, :integer
    field :opening_liability_cents, :integer

    belongs_to :finance_reporting, GroupStay.Reservations.FinanceReporting
    belongs_to :hotel_credit_lot, GroupStay.Reservations.HotelCreditLot

    timestamps(type: :utc_datetime)
  end
end
