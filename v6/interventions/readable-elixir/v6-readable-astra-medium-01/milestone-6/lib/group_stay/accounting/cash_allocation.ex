defmodule GroupStay.Accounting.CashAllocation do
  @moduledoc """
  A portion of cash in one room and one current disposition. Splitting a portion
  preserves its payment identity; a nil identity denotes pre-journal funding.
  Settled portions remain as accounting history after a room is cancelled.
  `allocation_order` is shared with credit allocations. Disposition splits keep
  that order; a transfer creates a new position in the destination account.
  """
  use Ecto.Schema

  schema "cash_allocations" do
    field :group_id, :string
    field :room_id, :string
    field :allocation_order, :integer
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :disposition, :string, default: "held"
  end
end
