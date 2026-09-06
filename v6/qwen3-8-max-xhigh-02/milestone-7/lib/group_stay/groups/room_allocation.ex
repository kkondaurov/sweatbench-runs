defmodule GroupStay.Groups.RoomAllocation do
  @moduledoc """
  Cash or hotel credit from one funding operation currently held on one
  room's deposit.

  Funding fills active rooms in their original order; allocations record
  the fill so settlements, reductions, and chargebacks can move the held
  amounts in fill order (or its reverse) without changing any other
  funding.
  """

  use Ecto.Schema

  alias GroupStay.Groups.{CashPayment, CreditApplication, Room}

  schema "room_allocations" do
    field :amount_cents, :integer

    belongs_to :room, Room
    belongs_to :cash_payment, CashPayment
    belongs_to :credit_application, CreditApplication

    timestamps()
  end
end
