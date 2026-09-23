defmodule GroupStay.RoomAccounting do
  @moduledoc """
  Allocation of a group's funding to its rooms.

  Cash and credit fund active rooms' deposits in the rooms' original order, filling one room's
  deposit before moving to the next. Cash is recorded as `GroupStay.Groups.CashAllocation`s and
  credit as `GroupStay.Credits.CreditApplication`s, each funding one room. Changes are made
  through `GroupStay.PartnerOperations`.
  """

  import Ecto.Query

  alias GroupStay.Credits.CreditApplication
  alias GroupStay.Groups.{CashAllocation, Group, Room}
  alias GroupStay.Repo

  @doc "A group's rooms in their original order, with the funding currently allocated to each."
  def rooms(%Group{id: group_ref}) do
    cash = funding_by_room(CashAllocation, group_ref, "held")
    credit = funding_by_room(CreditApplication, group_ref, "applied")

    from(r in Room, where: r.group_ref == ^group_ref, order_by: r.position)
    |> Repo.all()
    |> Enum.map(fn room ->
      %{
        room
        | cash_paid_cents: Map.get(cash, room.id, 0),
          credit_paid_cents: Map.get(credit, room.id, 0)
      }
    end)
  end

  defp funding_by_room(schema, group_ref, status) do
    from(f in schema,
      where: f.group_ref == ^group_ref and f.status == ^status,
      group_by: f.room_ref,
      select: {f.room_ref, sum(f.amount_cents)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Splits funding `pieces` (`{key, amount}` in funding order) across the group's active rooms.
  Returns `{key, room_ref, amount}` portions in fill order. Funding beyond every room's deposit,
  which only a group without rooms can receive, is returned with a `nil` room.
  """
  def fill(%Group{} = group, pieces) do
    capacities =
      for %Room{status: "active"} = room <- rooms(group),
          do: {room.id, room.deposit_cents - room.cash_paid_cents - room.credit_paid_cents}

    {portions, _capacities} =
      Enum.flat_map_reduce(pieces, capacities, fn {key, amount}, capacities ->
        {portions, capacities} = fill_rooms(capacities, amount)
        {Enum.map(portions, fn {room_ref, taken} -> {key, room_ref, taken} end), capacities}
      end)

    portions
  end

  defp fill_rooms(capacities, amount) do
    {portions, capacities, left} =
      Enum.reduce(capacities, {[], [], amount}, fn {room_ref, capacity}, {portions, rest, left} ->
        taken = min(max(capacity, 0), left)
        portions = if taken > 0, do: [{room_ref, taken} | portions], else: portions
        {portions, [{room_ref, capacity - taken} | rest], left - taken}
      end)

    portions = if left > 0, do: [{nil, left} | portions], else: portions
    {Enum.reverse(portions), Enum.reverse(capacities)}
  end
end
