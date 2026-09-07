defmodule GroupStay.Accounting.Allocation do
  @moduledoc """
  Funding currently held on an active room, from either cash or one credit lot.
  Settlement removes allocations; cash dispositions remain on the payment account.
  IDs record allocation order, including transfers and fills of gaps reopened by
  payment corrections. Transferred slices get new IDs at their destination; any
  portion left behind keeps its original place in that order.
  """
  use Ecto.Schema

  schema "room_allocations" do
    belongs_to :room, GroupStay.Reservations.Room
    belongs_to :cash_payment, GroupStay.Accounting.CashPayment
    belongs_to :credit_lot, GroupStay.HotelCredit.Lot
    field :amount_cents, :integer
  end
end
