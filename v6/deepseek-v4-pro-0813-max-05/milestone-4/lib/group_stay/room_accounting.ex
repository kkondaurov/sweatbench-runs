defmodule GroupStay.RoomAccounting do
  @moduledoc """
  Room-level allocation of applied funding.

  Cash and credit fund active room deposits in the rooms' original order,
  filling one room's deposit before moving to the next. Funding operations
  allocate in operation-processing order; allocations have incrementing
  integer ids, so removals run in reverse fill order.
  """

  alias GroupStay.{CreditApplication, Groups, Payment, Repo, Room, RoomAllocation}

  import Ecto.Query

  @held "held"

  @doc "An active room's deposit requirement in cents."
  def room_deposit(group, room) do
    Groups.room_deposit(room.nightly_rate_cents, group.rate_plan, Groups.nights(group))
  end

  @doc "The group's active rooms in their original order."
  def active_rooms(group) do
    Repo.all(
      from(r in Room,
        where: r.group_id == ^group.id and r.status == "active",
        order_by: [asc: r.position]
      )
    )
  end

  @doc "Sums of held chunks per room: `%{room_id => money}`."
  def held_by_room(room_ids) do
    held_map(room_ids)
  end

  defp held_map(room_ids) do
    Repo.all(
      from(a in RoomAllocation,
        where:
          a.room_id in ^room_ids and a.status == @held and
            a.amount_cents > 0,
        group_by: a.room_id,
        select: {a.room_id, sum(a.amount_cents)}
      )
    )
    |> Map.new()
  end

  @doc """
  Splits held amounts by kind for every room of `group`.

  Returns `%{room_id => %{cash: cents, credit: cents}}`.
  """
  def held_by_room_and_kind(group) do
    rows =
      Repo.all(
        from(a in RoomAllocation,
          where:
            a.group_id == ^group.id and a.status == @held and
              a.amount_cents > 0,
          group_by: [a.room_id, a.kind],
          select: {a.room_id, a.kind, sum(a.amount_cents)}
        )
      )

    Enum.reduce(rows, %{}, fn {room_id, kind, total}, acc ->
      money = Map.get(acc, room_id, %{cash: 0, credit: 0})

      money =
        case kind do
          "cash" -> %{money | cash: total}
          "credit" -> %{money | credit: total}
        end

      Map.put(acc, room_id, money)
    end)
  end

  @doc "Total held cash and credit funding the group's deposit, in cents."
  def held_totals(group), do: aggregate_held(group)

  defp aggregate_held(group) do
    rows =
      Repo.all(
        from(a in RoomAllocation,
          where:
            a.group_id == ^group.id and a.status == @held and
              a.amount_cents > 0,
          group_by: a.kind,
          select: {a.kind, sum(a.amount_cents)}
        )
      )
      |> Map.new()

    %{
      cash: Map.get(rows, "cash", 0),
      credit: Map.get(rows, "credit", 0)
    }
  end

  @doc "Cash from `payment` still held on active rooms, in cents."
  def held_cash(%Payment{id: id}) do
    Repo.aggregate(
      from(a in RoomAllocation,
        where:
          a.payment_id == ^id and a.kind == "cash" and a.status == @held and
            a.amount_cents > 0
      ),
      :sum,
      :amount_cents
    ) || 0
  end

  @doc "Credit from `application` still held on active rooms, in cents."
  def held_credit(%CreditApplication{id: id}) do
    Repo.aggregate(
      from(a in RoomAllocation,
        where:
          a.credit_application_id == ^id and a.kind == "credit" and
            a.status == @held and a.amount_cents > 0
      ),
      :sum,
      :amount_cents
    ) || 0
  end

  @doc "Credit from `lot` still applied to active groups, in cents."
  def lot_applied_credit(lot_id) do
    Repo.aggregate(
      from(a in RoomAllocation,
        join: c in CreditApplication,
        on: c.id == a.credit_application_id,
        where:
          c.lot_id == ^lot_id and a.kind == "credit" and
            a.status == @held and a.amount_cents > 0
      ),
      :sum,
      :amount_cents
    ) || 0
  end

  @doc "Allocates cash from `payment` across the group's active rooms."
  def allocate_cash(group, payment, amount), do: allocate(group, "cash", amount, payment.id, nil)

  @doc "Allocates credit from `application` across the group's active rooms."
  def allocate_credit(group, application, amount),
    do: allocate(group, "credit", amount, nil, application.id)

  defp allocate(group, kind, amount, payment_id, application_id) do
    rooms = active_rooms(group)
    holds = held_map(Enum.map(rooms, & &1.id))
    fund(group, rooms, holds, kind, amount, payment_id, application_id)
  end

  defp fund(_group, _rooms, _holds, _kind, 0, _payment_id, _application_id), do: :ok

  defp fund(_group, [], _holds, _kind, remaining, _payment_id, _application_id)
       when remaining <= 0,
       do: :ok

  defp fund(group, [], _holds, _kind, remaining, _payment_id, _application_id)
       when remaining > 0 do
    raise "funding allocation of #{remaining} exceeded group #{inspect(group.group_id)}'s unfunded deposit"
  end

  defp fund(group, [room | rooms], holds, kind, remaining, payment_id, application_id) do
    due = room_deposit(group, room)
    held = Map.get(holds, room.id, 0)
    gap = max(due - held, 0)
    take = min(gap, remaining)

    if take > 0 do
      Repo.insert!(%RoomAllocation{
        room_id: room.id,
        group_id: group.id,
        kind: kind,
        amount_cents: take,
        payment_id: payment_id,
        credit_application_id: application_id
      })
    end

    fund(group, rooms, holds, kind, remaining - take, payment_id, application_id)
  end

  @doc """
  Removes `amount` of a payment's held cash in reverse fill order and marks
  fully removed chunks with `status`. Returns :ok.
  """
  def remove_held_cash_reverse(%Payment{id: id}, amount, status) do
    chunks =
      Repo.all(
        from(a in RoomAllocation,
          where:
            a.payment_id == ^id and a.kind == "cash" and a.status == @held and
              a.amount_cents > 0,
          order_by: [desc: a.id]
        )
      )

    reduce_chunks(chunks, amount, status)
    :ok
  end

  defp reduce_chunks(_chunks, 0, _status), do: :ok

  defp reduce_chunks([], remaining, _status) when remaining > 0 do
    raise "removal of #{remaining} exceeded the payment's held cash"
  end

  defp reduce_chunks([chunk | rest], remaining, status) do
    take = min(chunk.amount_cents, remaining)

    Repo.update_all(
      from(a in RoomAllocation, where: a.id == ^chunk.id),
      set: [amount_cents: chunk.amount_cents - take]
    )

    if take == chunk.amount_cents do
      Repo.update_all(
        from(a in RoomAllocation, where: a.id == ^chunk.id),
        set: [status: status]
      )
    end

    reduce_chunks(rest, remaining - take, status)
  end

  @doc "Reclassifies all of a payment's held cash and returns the amount."
  def void_held_cash(%Payment{id: id}) do
    chunks =
      Repo.all(
        from(a in RoomAllocation,
          where:
            a.payment_id == ^id and a.kind == "cash" and a.status == @held and
              a.amount_cents > 0
        )
      )

    total = Enum.reduce(chunks, 0, fn chunk, acc -> chunk.amount_cents + acc end)

    ids = Enum.map(chunks, & &1.id)

    if ids != [] do
      Repo.update_all(
        from(a in RoomAllocation, where: a.id in ^ids),
        set: [amount_cents: 0, status: "charged_back"]
      )
    end

    total
  end

  @doc "Held cash chunks on the given rooms, in fill order."
  def held_cash_chunks(room_ids) do
    Repo.all(
      from(a in RoomAllocation,
        where:
          a.room_id in ^room_ids and a.kind == "cash" and a.status == @held and
            a.amount_cents > 0,
        order_by: [asc: a.id]
      )
    )
  end

  @doc "Held credit chunks on the given rooms, in fill order."
  def held_credit_chunks(room_ids) do
    Repo.all(
      from(a in RoomAllocation,
        where:
          a.room_id in ^room_ids and a.kind == "credit" and a.status == @held and
            a.amount_cents > 0,
        order_by: [asc: a.id]
      )
    )
  end

  @doc "Marks the given allocation ids as settled."
  def mark_settled(ids) when is_list(ids) and ids != [] do
    Repo.update_all(
      from(a in RoomAllocation, where: a.id in ^ids and a.status == @held),
      set: [status: "settled"]
    )

    :ok
  end

  def mark_settled(_ids), do: :ok
end
