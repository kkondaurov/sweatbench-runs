defmodule GroupStay.Deposits.CashAllocation do
  @moduledoc """
  Cash currently held against one active room's deposit.

  A nil `payment_operation_id` identifies the senior block imported from releases which predate
  durable operation receipts. Rows otherwise retain the payment identity needed for reductions
  and chargebacks.
  """

  use Ecto.Schema

  alias GroupStay.Deposits.{Group, Room}

  schema "cash_allocations" do
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :allocation_order, :integer

    belongs_to :group, Group
    belongs_to :room, Room

    timestamps(type: :utc_datetime)
  end
end
