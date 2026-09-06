defmodule GroupStay.Funding do
  @moduledoc """
  Cash funding of room deposits.

  Cash from each recorded payment (and the unattributed senior block of legacy
  funding, whose `payment_operation_id` is `nil`) fills active room deposits
  in the rooms' original order. Every cent of a payment stays allocated as it
  settles: held on a room, refunded, retained, converted to credit, reduced by
  a provider correction, or charged back. The allocations are the single
  source for the room paid amounts, the per-payment statement, and the cash
  ledger.

  Held cash and held hotel credit share one allocation sequence, so a deposit
  transfer can move the most recently created funding first regardless of
  funding kind. A transfer only repoints allocations at the destination
  group's rooms; every moved unit keeps its provenance (the payment identity
  or the credit lot).
  """

  import Ecto.Changeset
  import Ecto.Query

  alias GroupStay.Credits.CreditApplication
  alias GroupStay.Groups.CashAllocation
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  @doc """
  Allocates cash to the given rooms in order, filling one room's remaining
  deposit before moving to the next. The caller guarantees the amount fits.
  """
  def fill(%Group{} = group, rooms, amount, payment_operation_id) do
    Enum.reduce(rooms, amount, fn room, remaining ->
      need = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
      take = min(remaining, max(need, 0))

      if take > 0 do
        insert_allocation!(group, room, payment_operation_id, take, "held")
        bump_room!(room, cash: take)
      end

      remaining - take
    end)

    :ok
  end

  @doc """
  Moves the held cash on the given rooms to the settlement status, returning
  the settled allocations (in fill order). The rooms' paid amounts are
  reduced; the rooms themselves are marked cancelled separately.
  """
  def settle(rooms, status) do
    rooms
    |> held_on_rooms()
    |> Enum.map(fn allocation ->
      bump_room!(allocation.room, cash: -allocation.amount_cents)
      update_status!(allocation, status)
    end)
  end

  @doc """
  The allocations of one payment in fill order.
  """
  def allocations(payment_operation_id) do
    Repo.all(
      from a in CashAllocation,
        where: a.payment_operation_id == ^payment_operation_id,
        order_by: [asc: a.id],
        preload: [:room]
    )
  end

  @doc """
  The current disposition of one payment's cash, summed by status.
  """
  def dispositions(payment_operation_id) do
    payment_operation_id
    |> allocations()
    |> Enum.reduce(%{}, fn allocation, sums ->
      Map.update(
        sums,
        allocation.status,
        allocation.amount_cents,
        &(&1 + allocation.amount_cents)
      )
    end)
  end

  @doc """
  Cash sums by disposition across all payments and the legacy block.
  """
  def totals_by_status do
    from(a in CashAllocation, group_by: a.status, select: {a.status, sum(a.amount_cents)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Removes `amount` of the payment's held cash in reverse allocation order
  (across whichever groups currently hold it), marking it reduced. The rooms'
  outstanding deposit reopens. Returns a map of group id to the amount removed
  from that group; the caller guarantees it does not exceed the held cash.
  """
  def reduce(payment_operation_id, amount) do
    payment_operation_id
    |> allocations()
    |> Enum.filter(&(&1.status == "held"))
    |> Enum.sort_by(&sequence_of/1, :desc)
    |> Enum.reduce({amount, %{}}, fn allocation, {remaining, by_group} ->
      take = min(remaining, allocation.amount_cents)

      if take > 0 do
        bump_room!(allocation.room, cash: -take)
        split_off!(allocation, take, "reduced")
        {remaining - take, Map.update(by_group, allocation.group_id, take, &(&1 + take))}
      else
        {remaining, by_group}
      end
    end)
    |> elem(1)
  end

  @doc """
  Moves every remaining disposition of the payment (except cash already
  recorded as reduced) to charged-back cash. Held allocations, wherever they
  currently fund rooms, are removed in reverse allocation order, reopening
  the rooms' outstanding deposit. Returns the total charged back, a map of
  group id to the amount that had been held in that group, and the
  reclassified shares as `%{group_id, status, amount_cents}` entries naming
  each allocation's disposition before the chargeback.
  """
  def charge_back(payment_operation_id) do
    allocations = allocations(payment_operation_id)

    {total, held_by_group, reclassified} =
      allocations
      |> Enum.filter(&(&1.status == "held"))
      |> Enum.sort_by(&sequence_of/1, :desc)
      |> Enum.reduce({0, %{}, []}, fn allocation, {total, by_group, reclassified} ->
        bump_room!(allocation.room, cash: -allocation.amount_cents)
        update_status!(allocation, "charged_back")

        {
          total + allocation.amount_cents,
          Map.update(
            by_group,
            allocation.group_id,
            allocation.amount_cents,
            &(&1 + allocation.amount_cents)
          ),
          [
            %{
              group_id: allocation.group_id,
              status: "held",
              amount_cents: allocation.amount_cents
            }
            | reclassified
          ]
        }
      end)

    {total, reclassified} =
      allocations
      |> Enum.filter(&(&1.status in ~w(refunded retained converted)))
      |> Enum.reduce({total, reclassified}, fn allocation, {total, reclassified} ->
        update_status!(allocation, "charged_back")

        {
          total + allocation.amount_cents,
          [
            %{
              group_id: allocation.group_id,
              status: allocation.status,
              amount_cents: allocation.amount_cents
            }
            | reclassified
          ]
        }
      end)

    {total, held_by_group, Enum.reverse(reclassified)}
  end

  @doc """
  Moves `amount` of held funding out of the source's active rooms into the
  destination's active rooms, in reverse allocation order (the most recently
  created unit first), regardless of funding kind. The destination rooms fill
  in their original order with the units in draw order, and every moved unit
  keeps its provenance (payment identity or credit lot). Nothing settles or
  revalues, so the totals destinations stay within the caller's guarantees.
  Returns the moved amounts as `{cash, credit}`.
  """
  def transfer(%Group{} = source, %Group{} = destination, destination_rooms, amount) do
    draws =
      source.id
      |> held_units()
      |> draw_units(amount)

    needs =
      destination_rooms
      |> Enum.map(fn room ->
        {room, room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents}
      end)
      |> Enum.filter(fn {_room, need} -> need > 0 end)

    move_units!(destination, draws, needs, {0, 0})
  end

  # Held funding units of a group (cash and credit) from the most recently
  # created allocation back.
  defp held_units(group_id) do
    cash =
      Repo.all(
        from a in CashAllocation,
          where: a.group_id == ^group_id and a.status == "held",
          select: %{
            kind: :cash,
            id: a.id,
            seq: a.allocation_seq,
            amount_cents: a.amount_cents,
            room_id: a.room_id,
            payment_operation_id: a.payment_operation_id
          }
      )

    credit =
      Repo.all(
        from a in CreditApplication,
          where: a.group_id == ^group_id,
          select: %{
            kind: :credit,
            id: a.id,
            seq: a.allocation_seq,
            amount_cents: a.amount_cents,
            room_id: a.room_id,
            credit_lot_id: a.credit_lot_id
          }
      )

    Enum.sort_by(cash ++ credit, &(&1.seq || 0), :desc)
  end

  # Tags each unit with the amount drawn from it in reverse allocation order;
  # only the boundary unit is partially drawn. `left` tracks how much of the
  # unit is still on the source while its shares move onto destination rooms.
  defp draw_units(units, amount) do
    units
    |> Enum.map_reduce(amount, fn unit, remaining ->
      take = min(remaining, unit.amount_cents)
      {unit |> Map.put(:taken, take) |> Map.put(:left, unit.amount_cents), remaining - take}
    end)
    |> elem(0)
    |> Enum.filter(&(&1.taken > 0))
  end

  defp move_units!(_destination, [], _needs, {cash, credit}), do: {cash, credit}

  # Walks the drawn units into the destination rooms' remaining needs; both
  # queues stay aligned because the drawn amount fits the outstanding
  # deposit, and zero-need rooms were filtered out upfront.
  defp move_units!(destination, [draw | rest], [{room, need} | waiting], totals) do
    take = min(min(draw.taken, need), draw.left)
    move_draw!(destination, room, draw, take)

    moved = %{draw | taken: draw.taken - take, left: draw.left - take}

    move_units!(
      destination,
      if(draw.taken == take, do: rest, else: [moved | rest]),
      if(need == take, do: waiting, else: [{room, need - take} | waiting]),
      add_total(totals, draw.kind, take)
    )
  end

  defp add_total({cash, credit}, :cash, take), do: {cash + take, credit}
  defp add_total({cash, credit}, :credit, take), do: {cash, credit + take}

  # Moves one share of a drawn unit onto the destination room: the source
  # unit's row follows its funding to the destination when its remaining
  # amount moves in full, otherwise the remainder stays put and only the
  # moved share is re-created. A fully moved row keeps its identity (and
  # provenance) while taking the most recent sequence position on the
  # destination, so no allocation row ever carries zero cents.
  defp move_draw!(destination, room, draw, take) do
    bump_rooms!(draw.room_id, draw.kind, -take)
    bump_rooms!(room.id, draw.kind, take)

    seq = next_allocation_seq!()

    case draw.kind do
      :cash ->
        allocation = Repo.get!(CashAllocation, draw.id)

        if take == draw.left do
          allocation
          |> change(
            group_id: destination.id,
            room_id: room.id,
            allocation_seq: seq
          )
          |> Repo.update!()
        else
          allocation
          |> change(amount_cents: allocation.amount_cents - take)
          |> Repo.update!()

          insert_allocation!(destination, room, draw.payment_operation_id, take, "held", seq)
        end

      :credit ->
        application = Repo.get!(CreditApplication, draw.id)

        if take == draw.left do
          application
          |> change(
            group_id: destination.id,
            room_id: room.id,
            allocation_seq: seq
          )
          |> Repo.update!()
        else
          application
          |> change(amount_cents: application.amount_cents - take)
          |> Repo.update!()

          %CreditApplication{}
          |> change(
            credit_lot_id: draw.credit_lot_id,
            group_id: destination.id,
            room_id: room.id,
            amount_cents: take,
            allocation_seq: seq
          )
          |> Repo.insert!()
        end
    end
  end

  @doc """
  The position one past the highest allocation sequence ever used. Both
  funding kinds draw from this one sequence so transfers can order them.
  Must run inside the operation's transaction.
  """
  def next_allocation_seq! do
    cash = Repo.one(from a in CashAllocation, select: max(a.allocation_seq)) || 0
    credit = Repo.one(from a in CreditApplication, select: max(a.allocation_seq)) || 0
    max(cash, credit) + 1
  end

  defp sequence_of(%{allocation_seq: nil}), do: 0
  defp sequence_of(%{allocation_seq: seq}), do: seq

  defp held_on_rooms(rooms) do
    room_ids = Enum.map(rooms, & &1.id)

    Repo.all(
      from a in CashAllocation,
        where: a.room_id in ^room_ids and a.status == "held",
        order_by: [asc: a.id],
        preload: [:room]
    )
  end

  defp insert_allocation!(group, room, payment_operation_id, amount, status) do
    insert_allocation!(group, room, payment_operation_id, amount, status, next_allocation_seq!())
  end

  defp insert_allocation!(group, room, payment_operation_id, amount, status, seq) do
    %CashAllocation{}
    |> change(
      group_id: group.id,
      room_id: room.id,
      payment_operation_id: payment_operation_id,
      amount_cents: amount,
      status: status,
      allocation_seq: seq
    )
    |> Repo.insert!()
  end

  # Moves `amount` out of a held allocation into a new status: the whole row
  # flips when it is fully consumed, otherwise it splits.
  defp split_off!(allocation, amount, status) do
    if amount == allocation.amount_cents do
      update_status!(allocation, status)
    else
      allocation
      |> change(amount_cents: allocation.amount_cents - amount)
      |> Repo.update!()

      %CashAllocation{}
      |> change(
        group_id: allocation.group_id,
        room_id: allocation.room_id,
        payment_operation_id: allocation.payment_operation_id,
        amount_cents: amount,
        status: status,
        allocation_seq: next_allocation_seq!()
      )
      |> Repo.insert!()
    end
  end

  defp update_status!(allocation, status) do
    allocation
    |> change(status: status)
    |> Repo.update!()
  end

  # Atomic increments avoid stale reads when several funding changes touch
  # the same room.
  defp bump_room!(%Room{} = room, cash: cash_delta) do
    Repo.update_all(
      from(r in Room, where: r.id == ^room.id),
      inc: [cash_paid_cents: cash_delta]
    )
  end

  defp bump_rooms!(room_id, :cash, delta) do
    Repo.update_all(
      from(r in Room, where: r.id == ^room_id),
      inc: [cash_paid_cents: delta]
    )
  end

  defp bump_rooms!(room_id, :credit, delta) do
    Repo.update_all(
      from(r in Room, where: r.id == ^room_id),
      inc: [credit_paid_cents: delta]
    )
  end
end
