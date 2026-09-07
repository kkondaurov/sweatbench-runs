defmodule GroupStay.RoomAccounting.AllocationOrder do
  @moduledoc """
  A shared, durable creation sequence for cash and credit allocations. Database
  triggers assign positions, including for splits and transfers, in the same write
  transaction as the allocation. Removing part of a held allocation leaves its
  original position intact.
  """
  import Ecto.Query
  alias GroupStay.{CashAllocation, Repo}
  alias GroupStay.Credits.Allocation

  def held(group_id) do
    cash =
      Repo.all(
        from a in CashAllocation, where: a.group_id == ^group_id and a.disposition == "held"
      )

    credit = Repo.all(from a in Allocation, where: a.group_id == ^group_id)
    newest_first(cash ++ credit)
  end

  def newest_first(allocations) do
    cash_ids = for %CashAllocation{id: id} <- allocations, do: id
    credit_ids = for %Allocation{id: id} <- allocations, do: id

    positions =
      Repo.all(
        from o in "allocation_order",
          where:
            (o.kind == "cash" and o.allocation_id in ^cash_ids) or
              (o.kind == "credit" and o.allocation_id in ^credit_ids),
          select: {{o.kind, o.allocation_id}, o.id}
      )
      |> Map.new()

    Enum.sort_by(allocations, &Map.fetch!(positions, {kind(&1), &1.id}), :desc)
  end

  defp kind(%CashAllocation{}), do: "cash"
  defp kind(%Allocation{}), do: "credit"
end
