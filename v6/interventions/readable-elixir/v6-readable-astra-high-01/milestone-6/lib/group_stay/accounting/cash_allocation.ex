defmodule GroupStay.Accounting.CashAllocation do
  @moduledoc """
  A slice of cash from a payment, with its current room and disposition.

  A nil payment identifier denotes the senior, unattributed funding inherited
  from releases without durable receipts. Settled slices remain as history.
  """
  use Ecto.Schema

  schema "cash_allocations" do
    field :group_id, :string
    field :room_id, :string
    field :payment_operation_id, :string
    field :allocation_order, :integer
    field :amount_cents, :integer
    field :disposition, :string, default: "held"
  end
end
