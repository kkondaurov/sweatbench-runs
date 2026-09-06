defmodule GroupStay.Deposits.CashAllocation do
  use Ecto.Schema

  @moduledoc """
  Cash held by one room. `payment_operation_id` is `nil` for the unattributed
  senior block created from funding that predates durable operation records.

  Rows are never deleted. A held row (`disposed` is `nil`) sits on an active
  room; settlement or reduction marks its disposition instead. The six
  dispositions of any payment's rows therefore always sum to the recorded
  amount: held, refunded, retained, converted, reduced, and charged back.
  """

  schema "cash_allocations" do
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :disposed, :string

    belongs_to :group, GroupStay.Deposits.Group
    belongs_to :room, GroupStay.Deposits.Room

    timestamps(type: :naive_datetime_usec)
  end
end
