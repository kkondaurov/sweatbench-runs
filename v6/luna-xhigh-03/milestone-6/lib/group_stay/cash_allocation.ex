defmodule GroupStay.CashAllocation do
  @moduledoc "Cash currently funding one active room."

  use Ecto.Schema

  schema "cash_allocations" do
    field :group_id, :string
    field :room_id, :string
    field :room_index, :integer
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :allocation_order, :integer
  end
end
