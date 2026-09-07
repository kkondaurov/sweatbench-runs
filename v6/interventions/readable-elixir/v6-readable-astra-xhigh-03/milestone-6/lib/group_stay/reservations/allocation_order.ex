defmodule GroupStay.Reservations.AllocationOrder do
  @moduledoc """
  Gives cash and hotel-credit room allocations one shared creation order.

  Callers hold the reservations transaction's write lock. Transfers insert new
  destination portions before removing source portions, so the highest order
  always survives and newly allocated funding is always last.
  """
  alias GroupStay.Repo
  alias GroupStay.Reservations.{CashAllocation, RoomCreditAllocation}

  def insert!(allocation) do
    latest_cash = Repo.aggregate(CashAllocation, :max, :allocation_order) || 0
    latest_credit = Repo.aggregate(RoomCreditAllocation, :max, :allocation_order) || 0

    Repo.insert!(%{allocation | allocation_order: max(latest_cash, latest_credit) + 1})
  end
end
