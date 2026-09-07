defmodule GroupStay.Reservations.CreditAllocation do
  @moduledoc """
  An immutable record of a lot funding a group's deposit.

  RoomCreditAllocation records its room portions and which remain active.
  Those portions stay a liability regardless of the lot's expiry. Refundable
  settlement restores them; nonrefundable settlement consumes them. This
  original redemption record remains unchanged after either settlement.
  """
  use Ecto.Schema

  schema "credit_allocations" do
    field :group_id, :string
    field :credit_lot_id, :id
    field :operation_id, :string
    field :occurred_on, :date
    field :amount_cents, :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
