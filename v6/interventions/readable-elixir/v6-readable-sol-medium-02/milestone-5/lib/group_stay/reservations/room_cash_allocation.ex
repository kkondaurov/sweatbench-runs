defmodule GroupStay.Reservations.RoomCashAllocation do
  @moduledoc "Cash held against one active room, optionally attributed to a durable payment."

  use Ecto.Schema

  alias GroupStay.Reservations.{CashPaymentAccounting, FundingAllocationSequence, Room}

  schema "room_cash_allocations" do
    field :amount_cents, :integer
    belongs_to :room, Room
    belongs_to :payment_accounting, CashPaymentAccounting
    belongs_to :allocation_sequence, FundingAllocationSequence
    timestamps(type: :utc_datetime)
  end
end
