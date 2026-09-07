defmodule GroupStay.Reservations.CashAllocation do
  @moduledoc """
  The current dispositions of a portion of one cash payment allocated to a room.

  The six balances always sum to `amount_cents`. Transfers split held portions
  into new allocations, retaining payment identity and marking participation
  permanently, including after settlement or correction. `allocation_order`
  shares a creation order with hotel-credit room allocations. A nil payment
  identifier denotes the senior, unattributed cash from earlier releases.
  """
  use Ecto.Schema

  schema "cash_allocations" do
    field :group_id, :string
    field :room_id, :string
    field :payment_operation_id, :string
    field :allocation_order, :integer
    field :transferred, :boolean, default: false
    field :amount_cents, :integer
    field :held_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
  end
end
