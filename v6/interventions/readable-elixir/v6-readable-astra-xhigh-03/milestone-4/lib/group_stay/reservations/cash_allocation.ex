defmodule GroupStay.Reservations.CashAllocation do
  @moduledoc """
  The current dispositions of one cash payment's original allocation to a room.

  The six balances always sum to `amount_cents`. IDs preserve fill order, even
  when later funding fills holes left by corrections. A nil payment identifier
  denotes the senior, unattributed cash brought forward from earlier releases.
  """
  use Ecto.Schema

  schema "cash_allocations" do
    field :group_id, :string
    field :room_id, :string
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :held_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
  end
end
