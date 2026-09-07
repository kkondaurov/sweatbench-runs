defmodule GroupStay.Reservations.RoomCashAllocation do
  @moduledoc "Cash held against one active room, optionally attributed to a durable payment."

  use Ecto.Schema

  alias GroupStay.Reservations.{CashPaymentAccounting, Room}

  schema "room_cash_allocations" do
    field :amount_cents, :integer
    belongs_to :room, Room
    belongs_to :payment_accounting, CashPaymentAccounting
    timestamps(type: :utc_datetime)
  end
end
