defmodule GroupStay.Reservations.FinanceMovement do
  @moduledoc false

  use Ecto.Schema

  schema "finance_movements" do
    field :partner_operation_id, :string
    field :posting_on, :date
    field :entry_kind, :string
    field :property_id, :string
    field :classification, :string
    field :amount_cents, :integer
    field :available_delta_cents, :integer, default: 0
    field :late_adjustment, :boolean, default: false

    belongs_to :finance_reporting, GroupStay.Reservations.FinanceReporting
    belongs_to :cash_payment, GroupStay.Reservations.CashPayment
    belongs_to :hotel_credit_lot, GroupStay.Reservations.HotelCreditLot

    timestamps(type: :utc_datetime)
  end
end
