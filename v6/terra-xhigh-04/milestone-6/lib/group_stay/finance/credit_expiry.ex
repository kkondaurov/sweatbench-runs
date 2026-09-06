defmodule GroupStay.Finance.CreditExpiry do
  @moduledoc false

  use Ecto.Schema

  alias GroupStay.Groups.HotelCreditLot

  schema "finance_credit_expiries" do
    field :reporting_expires_on, :date

    belongs_to :hotel_credit_lot, HotelCreditLot

    timestamps(type: :utc_datetime)
  end
end
