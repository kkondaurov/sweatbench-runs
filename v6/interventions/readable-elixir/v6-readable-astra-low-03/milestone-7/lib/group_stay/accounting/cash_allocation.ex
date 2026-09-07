defmodule GroupStay.Accounting.CashAllocation do
  @moduledoc """
  A portion of cash in one disposition. Held portions belong to a room; settled
  portions retain their payment identity forever. A nil identity denotes legacy cash.
  Allocation positions share a sequence with credit, preserving creation order
  across funding kinds and groups. Transfers create new destination positions
  while keeping the payment identity; corrections follow that identity everywhere.

  For converted cash, one row carries the whole payment's entitlement in that
  lot. This avoids rounding by room; other rows for the same payment and lot carry
  zero entitlement. A chargeback visits all of the payment's rows exactly once.
  """
  use Ecto.Schema

  schema "cash_allocations" do
    field :group_id, :string
    field :allocation_position, :integer
    field :room_id, :string
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :disposition, :string, default: "held"
    field :credit_lot_id, :integer
    field :entitlement_cents, :integer, default: 0
  end
end
