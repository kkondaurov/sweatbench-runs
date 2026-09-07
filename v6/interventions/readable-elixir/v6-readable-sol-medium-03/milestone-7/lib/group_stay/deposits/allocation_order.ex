defmodule GroupStay.Deposits.AllocationOrder do
  @moduledoc """
  Assigns one ordering sequence to cash and credit allocations.

  Partner operations are serialized by the operation journal's immediate transaction, so reading
  the current maximum and assigning the next value is safe. A shared sequence lets transfers
  compare unlike funding kinds and lets later corrections unwind allocations consistently.
  """

  import Ecto.Query

  alias GroupStay.Deposits.{CashAllocation, CreditAllocation}
  alias GroupStay.Repo

  @doc "Returns the next allocation order inside a partner-operation transaction."
  def next do
    cash = Repo.one(from a in CashAllocation, select: max(a.allocation_order)) || 0
    credit = Repo.one(from a in CreditAllocation, select: max(a.allocation_order)) || 0
    max(cash, credit) + 1
  end
end
