defmodule GroupStay.Reservations.CashAllocation do
  @moduledoc """
  Cash from one payment funding one room's deposit.

  Cash fills the deposits of active rooms in the rooms' original order, so every cent GroupStay
  records is held against a room until something settles it. `status` is that cent's current
  disposition:

    * `held` - still funding an active room's deposit;
    * `refunded` - returned to the guest when their room was cancelled while refundable;
    * `retained` - kept by the hotel when their room was cancelled without a refund;
    * `converted` - turned into the hotel credit lot named by `converted_lot_id`;
    * `reduced` - the provider reported the recorded cash was overstated;
    * `charged_back` - the payment was reversed after the fact.

  `payment_operation_id` is the payment the cash came from, and is `nil` only for funding brought
  forward from before partner operations were durably recorded, which no operation can name.
  """

  use Ecto.Schema

  @held "held"
  @settled ~w(refunded retained converted)
  @statuses ~w(held refunded retained converted reduced charged_back)

  schema "cash_allocations" do
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :status, :string, default: @held

    belongs_to :group, GroupStay.Reservations.Group
    belongs_to :room, GroupStay.Reservations.Room
    belongs_to :converted_lot, GroupStay.Reservations.CreditLot

    timestamps(type: :utc_datetime)
  end

  def held, do: @held
  def statuses, do: @statuses

  @doc """
  The statuses a chargeback reclassifies: everything that is not already reduced or charged back.
  """
  def reversible_statuses, do: [@held | @settled]
end
