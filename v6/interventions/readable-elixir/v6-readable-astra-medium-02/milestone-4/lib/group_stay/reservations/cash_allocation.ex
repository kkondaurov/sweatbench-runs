defmodule GroupStay.Reservations.CashAllocation do
  @moduledoc """
  A slice of cash in one room, retaining its payment identity and current disposition.
  IDs preserve fill order. A nil payment identity denotes the senior legacy block.
  Settlements split slices without losing identity; converted slices retain their lot.
  """
  use Ecto.Schema

  schema "cash_allocations" do
    field :group_id, :string
    field :room_id, :string
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :disposition, :string, default: "held"
    field :credit_lot_id, :integer
  end
end
