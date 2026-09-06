defmodule GroupStay.Reservations.CashPayment do
  @moduledoc false

  use Ecto.Schema

  schema "cash_payments" do
    field :payment_operation_id, :string
    field :recorded_cents, :integer
    field :held_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
    field :transfer_participated, :boolean, default: false

    belongs_to :group_reservation, GroupStay.Reservations.GroupReservation
    has_many :room_funding_allocations, GroupStay.Reservations.RoomFundingAllocation
    has_many :credit_lot_cash_contributions, GroupStay.Reservations.CreditLotCashContribution

    timestamps(type: :utc_datetime)
  end
end
