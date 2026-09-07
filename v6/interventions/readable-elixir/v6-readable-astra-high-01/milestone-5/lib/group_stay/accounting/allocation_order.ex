defmodule GroupStay.Accounting.AllocationOrder do
  @moduledoc """
  A durable creation sequence shared by cash and credit room allocations.

  Transfers create new allocations at the destination. Partial withdrawals keep
  the remainder's original position; disposition changes do not create funding.
  The counter is updated inside the operation's serialized write transaction.
  """
  alias GroupStay.Repo

  def next do
    %{rows: [[position]]} =
      Repo.query!("UPDATE allocation_sequence SET position = position + 1 RETURNING position")

    position
  end
end
