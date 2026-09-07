defmodule GroupStay.Payments.CashAllocation do
  @moduledoc """
  A slice of cash with one current disposition. A nil payment identity denotes
  legacy funding. Converted slices retain the lot and its rounded entitlement.
  Splitting a held slice preserves its fill order for later reductions.
  """
  use Ecto.Schema

  schema "cash_allocations" do
    field :allocation_order, :integer
    field :group_id, :string
    field :room_id, :string
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :disposition, :string, default: "held"
    field :credit_lot_id, :id
    field :entitlement_cents, :integer, default: 0
  end
end
