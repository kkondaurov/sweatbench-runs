defmodule GroupStay.Reservations.FundingAllocationSequence do
  @moduledoc """
  A shared monotonic order for cash and hotel-credit allocations.

  Cash and credit use separate provenance tables, but transfers must compare their creation order.
  This row supplies that common ordering without weakening either table's foreign keys.
  """

  use Ecto.Schema

  schema "funding_allocation_sequences" do
    timestamps(type: :utc_datetime)
  end
end
