defmodule GroupStay.Reservations.RoomCreditAllocation do
  @moduledoc """
  The room portions of an original credit redemption, kept after settlement.

  Active portions pause expiry and count toward both liability and the lot's
  possible shortfall. Settling a room deactivates only its own portions.
  Transfers split or move portions without changing the original redemption or
  lot. `allocation_order` shares a creation order with cash room allocations.
  """
  use Ecto.Schema

  schema "room_credit_allocations" do
    field :group_id, :string
    field :room_id, :string
    field :credit_lot_id, :id
    field :credit_allocation_id, :id
    field :allocation_order, :integer
    field :amount_cents, :integer
    field :active, :boolean, default: true
  end
end
