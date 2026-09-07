defmodule GroupStay.FinanceReporting.CreditExpiryPosition do
  @moduledoc false

  use Ecto.Schema

  alias GroupStay.Reservations.HotelCreditLot

  schema "finance_credit_expiry_positions" do
    field :expires_on, :date
    field :amount_cents, :integer
    belongs_to :lot, HotelCreditLot

    timestamps(type: :utc_datetime)
  end
end
