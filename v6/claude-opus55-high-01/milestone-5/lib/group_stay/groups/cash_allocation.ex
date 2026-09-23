defmodule GroupStay.Groups.CashAllocation do
  @moduledoc """
  Cash from one payment allocated to one room's deposit, and what has become of it.

  `payment_operation_id` is the durable payment the cash came from, or `nil` for the unattributed
  block of funding received before durable operation records existed. `allocation_seq` is the
  order in which funding was allocated, shared with `GroupStay.Credits.CreditApplication`; rows
  split from one allocation keep its place. `room_ref` is `nil` only for cash that no room had
  deposit left to hold.

  Statuses:

    * `held` - funding an active room;
    * `refunded`, `retained`, `converted` - settled when the room was cancelled; converted cash
      records the credit lot it was issued into as `lot_ref`;
    * `reduced` - removed by a provider correction;
    * `charged_back` - reversed by a chargeback. `lot_ref` is kept for converted cash;
    * `transferred` - moved to another group by the transfer `transfer_operation_id`, where it is
      held by a new allocation carrying the same payment and transfer. It is not a disposition of
      the payment's cash.
  """
  use Ecto.Schema

  @timestamps_opts [type: :utc_datetime_usec]

  @statuses ~w(held refunded retained converted reduced charged_back)

  def statuses, do: @statuses

  schema "cash_allocations" do
    field :group_ref, :integer
    field :room_ref, :integer
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :status, :string
    field :lot_ref, :integer
    field :settled_on, :date
    field :allocation_seq, :integer
    field :transfer_operation_id, :string

    timestamps()
  end
end
