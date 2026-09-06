defmodule GroupStay.Reservations.Funding do
  @moduledoc """
  Room-level accounting for the cash and hotel credit that fund a group's deposit.

  Funding fills the deposits of active rooms in the rooms' original order, one room at a time, in
  the order the funding operations are processed. Every allocation remembers the payment or credit
  lot it came from, so a room can be settled, a payment reduced, or a payment charged back without
  disturbing the rest of the group.

  Cash allocations and hotel-credit applications are numbered from one sequence, so the two kinds
  of funding have a single allocation order between them. A transfer moves allocations to another
  group of the same guest instead of creating new ones: a moved part keeps its sequence, its
  payment or lot, and its place in the order corrections unwind.

  Every function here runs inside the transaction of the operation that called it.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.Finance
  alias GroupStay.Repo
  alias GroupStay.Reservations.CashAllocation
  alias GroupStay.Reservations.Credit
  alias GroupStay.Reservations.CreditApplication
  alias GroupStay.Reservations.Group
  alias GroupStay.Reservations.Room

  ## Rooms

  @doc """
  The group's rooms in their original order.
  """
  def rooms(%Group{id: id}) do
    Repo.all(from r in Room, where: r.group_id == ^id, order_by: [asc: r.position])
  end

  @doc """
  The group's rooms that still hold a deposit requirement, in their original order.
  """
  def active_rooms(%Group{} = group), do: Enum.filter(rooms(group), &Room.active?/1)

  @doc """
  The rooms `amount_cents` funds: active rooms in their original order, each room's deposit filled
  before the next room is touched.

  Returns `[{room, amount_cents}]`. The caller has already checked that the amount fits within the
  group's outstanding deposit, which is the sum of the plan's capacity.
  """
  def fill_plan(%Group{} = group, amount_cents) do
    {plan, _left} =
      group
      |> active_rooms()
      |> Enum.flat_map_reduce(amount_cents, fn room, left ->
        case min(left, Room.unfunded_deposit_cents(room)) do
          0 -> {[], left}
          take -> {[{room, take}], left - take}
        end
      end)

    plan
  end

  @doc """
  Walks two splits of the same amount together into the parts they have in common.

  Returns `[{left, right, amount_cents}]`. Filling rooms and drawing from lots or from existing
  allocations are two ways of dividing one amount, and this is where the two divisions meet.
  """
  def pair([], _rights), do: []

  def pair([{left, left_cents} | lefts], [{right, right_cents} | rights]) do
    taken = min(left_cents, right_cents)
    lefts = if left_cents > taken, do: [{left, left_cents - taken} | lefts], else: lefts
    rights = if right_cents > taken, do: [{right, right_cents - taken} | rights], else: rights

    [{left, right, taken} | pair(lefts, rights)]
  end

  @doc """
  The next place in the order allocations are created in.

  Cash and credit share the sequence, because a transfer draws from a group's funding in one order
  whatever kind each allocation is.
  """
  def next_seq, do: max(max_seq(CashAllocation), max_seq(CreditApplication)) + 1

  defp max_seq(schema), do: Repo.aggregate(schema, :max, :allocation_seq) || 0

  ## Recording funding

  @doc """
  Holds the cash of one payment against the rooms it funds.
  """
  def allocate_cash(%Group{} = group, payment_operation_id, amount_cents) do
    for {room, amount} <- fill_plan(group, amount_cents) do
      Repo.insert!(%CashAllocation{
        group_id: group.id,
        room_id: room.id,
        payment_operation_id: payment_operation_id,
        amount_cents: amount,
        status: CashAllocation.held(),
        allocation_seq: next_seq()
      })
    end

    :ok
  end

  ## Settling rooms

  @doc """
  Settles the funding held against `rooms` and cancels them.

  Cash is refunded, converted to one hotel credit lot, or retained, exactly as a whole-group
  cancellation settles it, and the credit bonus is calculated once on the rooms' combined cash.
  Credit returns to the lots it came from or is consumed with the rooms.
  """
  def settle_rooms(%Group{} = group, rooms, refund_method, refundable?, operation) do
    room_ids = Enum.map(rooms, & &1.id)
    allocations = held_allocations(room_ids)
    cash_cents = total_cents(allocations)
    posting = Finance.posting(operation)

    {status, lot, credit_issued_cents} =
      settle_cash(group, refund_method, refundable?, cash_cents, operation, posting)

    reclassify(allocations, status, lot)
    # The cash leaves the property that held it, whichever way the settlement sends it.
    Finance.record_cash(posting, group.property_id, cash_kind(status), cash_cents)
    settle_credit(room_ids, refundable?, operation.occurred_on, posting)
    cancel_rooms(room_ids)

    %{
      refunded_cents: if(status == "refunded", do: cash_cents, else: 0),
      retained_cents: if(status == "retained", do: cash_cents, else: 0),
      credit_issued_cents: credit_issued_cents
    }
  end

  # Hotel credit is only offered where a refund is, and the whole settlement earns one bonus.
  defp settle_cash(group, "hotel_credit", true, cash_cents, operation, posting) do
    {lot, credit_issued_cents} =
      Credit.issue(group, cash_cents, operation.operation_id, operation.occurred_on, posting)

    {"converted", lot, credit_issued_cents}
  end

  defp settle_cash(_group, _refund_method, true, _cash_cents, _operation, _posting),
    do: {"refunded", nil, 0}

  defp settle_cash(_group, _refund_method, false, _cash_cents, _operation, _posting),
    do: {"retained", nil, 0}

  # The report names converted cash after where it went; the other dispositions it names as they
  # are.
  defp cash_kind("converted"), do: "converted_to_credit"
  defp cash_kind(status), do: status

  # Credit that funded a room goes back to the lot it came from when the guest is still entitled
  # to a refund, and is kept by the hotel when they are not.
  defp settle_credit(room_ids, true, on, posting),
    do: Credit.restore(applied_credit(room_ids), on, posting)

  defp settle_credit(room_ids, false, _on, posting),
    do: Credit.consume(applied_credit(room_ids), posting)

  defp cancel_rooms(room_ids) do
    Repo.update_all(from(r in Room, where: r.id in ^room_ids), set: [status: "cancelled"])
  end

  ## Transferring held funding

  @doc """
  Moves `amount_cents` of held funding from one group to another group of the same guest.

  The source gives up its most recently created allocations first, whatever kind of funding each
  one is, and the destination takes what was drawn into its active rooms in the rooms' original
  order, in the order it was drawn. Nothing is settled or revalued: every moved allocation keeps
  its payment or its lot, its status, and its place in the allocation order.

  Returns the cash part of what moved, which is the part that is held at a property.
  """
  def transfer(%Group{} = source, %Group{} = destination, amount_cents) do
    plan =
      source
      |> held_units()
      |> draw_plan(amount_cents)
      |> pair(fill_plan(destination, amount_cents))

    plan
    |> Enum.chunk_by(fn {unit, _room, _amount} -> {unit.__struct__, unit.id} end)
    |> Enum.each(&move(&1, destination))

    Enum.sum(for {%CashAllocation{}, _room, moved_cents} <- plan, do: moved_cents)
  end

  # Everything currently funding one of the group's active rooms, most recently created first.
  defp held_units(%Group{id: id}) do
    cash = on_active_rooms(CashAllocation, id, CashAllocation.held())
    credit = on_active_rooms(CreditApplication, id, "applied")

    Enum.sort_by(cash ++ credit, &{&1.allocation_seq, &1.id}, :desc)
  end

  defp on_active_rooms(schema, group_id, status) do
    Repo.all(
      from a in schema,
        join: r in Room,
        on: r.id == a.room_id,
        where: a.group_id == ^group_id and a.status == ^status and r.status == "active"
    )
  end

  defp draw_plan(units, amount_cents) do
    {plan, _left} =
      Enum.flat_map_reduce(units, amount_cents, fn unit, left ->
        case min(left, unit.amount_cents) do
          0 -> {[], left}
          take -> {[{unit, take}], left - take}
        end
      end)

    plan
  end

  # An allocation that moves whole simply changes the room it funds. One that only partly moves,
  # or that spreads over more than one destination room, splits into parts that each carry
  # everything the original carried.
  defp move(parts, destination) do
    [{unit, _room, _amount} | _] = parts
    moved_cents = Enum.sum(Enum.map(parts, fn {_unit, _room, amount} -> amount end))

    parts =
      if moved_cents == unit.amount_cents do
        [{unit, room, amount_cents} | rest] = parts
        relocate(unit, destination, room, amount_cents)
        rest
      else
        unit |> Changeset.change(amount_cents: unit.amount_cents - moved_cents) |> Repo.update!()
        parts
      end

    for {unit, room, amount_cents} <- parts, do: copy(unit, destination, room, amount_cents)
  end

  defp relocate(%CashAllocation{} = unit, destination, room, amount_cents) do
    unit
    |> Changeset.change(
      group_id: destination.id,
      room_id: room.id,
      amount_cents: amount_cents,
      transferred: true
    )
    |> Repo.update!()
  end

  defp relocate(%CreditApplication{} = unit, destination, room, amount_cents) do
    unit
    |> Changeset.change(group_id: destination.id, room_id: room.id, amount_cents: amount_cents)
    |> Repo.update!()
  end

  defp copy(%CashAllocation{} = unit, destination, room, amount_cents) do
    Repo.insert!(%CashAllocation{
      group_id: destination.id,
      room_id: room.id,
      payment_operation_id: unit.payment_operation_id,
      amount_cents: amount_cents,
      status: unit.status,
      allocation_seq: unit.allocation_seq,
      transferred: true
    })
  end

  defp copy(%CreditApplication{} = unit, destination, room, amount_cents) do
    Repo.insert!(%CreditApplication{
      group_id: destination.id,
      room_id: room.id,
      credit_lot_id: unit.credit_lot_id,
      amount_cents: amount_cents,
      applied_on: unit.applied_on,
      status: unit.status,
      allocation_seq: unit.allocation_seq
    })
  end

  ## Reducing and reversing a payment

  @doc """
  Cash from a payment that is still held against active rooms.
  """
  def held_cash_cents(payment_operation_id) do
    payment_operation_id
    |> from_payment([CashAllocation.held()])
    |> sum_cents()
  end

  @doc """
  Cash from a payment that a chargeback would still have to reclassify.
  """
  def reversible_cash_cents(payment_operation_id) do
    payment_operation_id
    |> from_payment(CashAllocation.reversible_statuses())
    |> sum_cents()
  end

  @doc """
  Removes `amount_cents` of a payment's held cash, latest allocation first.

  A payment's cash can have been transferred into other groups, so its allocations unwind in
  reverse allocation order wherever they now fund rooms. The rooms' deposits reopen by the amounts
  removed; nothing that has already been settled moves. Returns the groups whose funding changed.
  """
  def reduce(payment_operation_id, amount_cents, posting) do
    payment_operation_id
    |> from_payment([CashAllocation.held()])
    |> latest_first()
    |> Repo.all()
    |> take_cents(amount_cents, "reduced", posting)
  end

  @doc """
  Reverses every remaining disposition of a payment.

  Held cash leaves the rooms it funded, reopening their deposit. Cash already refunded or retained
  only changes its classification: the money itself moved long ago. Converted cash also revokes
  the credit entitlement it bought.

  Returns `{charged_back_cents, group_ids}`, the cash reclassified and the groups whose funding it
  left.
  """
  def charge_back(payment_operation_id, posting) do
    allocations =
      payment_operation_id
      |> from_payment(CashAllocation.reversible_statuses())
      |> latest_first()
      |> Repo.all()

    revoke_entitlements(payment_operation_id, allocations, posting)
    record_chargeback(allocations, posting)
    reclassify(allocations, "charged_back", nil)

    {total_cents(allocations), held_group_ids(allocations)}
  end

  # A chargeback follows the cash to wherever it is held or was settled. Cash that had already
  # been refunded, retained, or converted is only reclassified, so the report states the earlier
  # classification coming back out as the chargeback goes in.
  defp record_chargeback(allocations, posting) do
    for allocation <- allocations do
      property_id = property_of(allocation)
      Finance.record_cash(posting, property_id, "charged_back", allocation.amount_cents)

      if allocation.status != CashAllocation.held() do
        Finance.record_cash(
          posting,
          property_id,
          cash_kind(allocation.status),
          -allocation.amount_cents
        )
      end
    end
  end

  defp latest_first(queryable),
    do: order_by(queryable, [a], desc: a.allocation_seq, desc: a.id)

  # Only cash that was still funding a room changes what its group holds; cash that was refunded,
  # retained, or converted long ago only changes how the ledger classifies it.
  defp held_group_ids(allocations) do
    for allocation <- allocations, allocation.status == CashAllocation.held(), uniq: true do
      allocation.group_id
    end
  end

  # Cash converted into a lot bought a share of it, so charging that cash back takes that share
  # out of the lot again. The share is calculated per lot, in the order the cash funded the rooms.
  defp revoke_entitlements(payment_operation_id, allocations, posting) do
    allocations
    |> Enum.filter(& &1.converted_lot_id)
    |> Enum.map(& &1.converted_lot_id)
    |> Enum.uniq()
    |> Enum.each(&Credit.claw_back(&1, entitlement_cents(&1, payment_operation_id), posting))
  end

  @doc """
  The credit one payment is entitled to in a lot.

  A lot is issued for the combined cash of a settlement, so its bonus is not divisible payment by
  payment. Each payment is instead worth what the lot grew by when its cash joined the ones funding
  the rooms before it, which makes the entitlements add up to the lot exactly.
  """
  def entitlement_cents(lot_id, payment_operation_id) do
    from(a in CashAllocation,
      where: a.converted_lot_id == ^lot_id,
      order_by: [asc: a.allocation_seq, asc: a.id],
      select: {a.payment_operation_id, a.amount_cents}
    )
    |> Repo.all()
    |> Enum.chunk_by(fn {payment, _amount} -> payment end)
    |> Enum.reduce({0, 0}, fn contributions, {settled_cents, entitlement} ->
      [{payment, _amount} | _] = contributions
      settled_after = settled_cents + total_of(contributions)

      if payment == payment_operation_id do
        {settled_after, Credit.value_of(settled_after) - Credit.value_of(settled_cents)}
      else
        {settled_after, entitlement}
      end
    end)
    |> elem(1)
  end

  defp total_of(contributions),
    do: Enum.sum(Enum.map(contributions, fn {_p, amount} -> amount end))

  ## Reading a payment

  @doc """
  Where the cash of one payment currently sits, keyed by disposition.
  """
  def dispositions(payment_operation_id) do
    from(a in CashAllocation,
      where: a.payment_operation_id == ^payment_operation_id,
      group_by: a.status,
      select: {a.status, sum(a.amount_cents)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Whether cash from a payment has ever taken part in a transfer.
  """
  def transferred?(payment_operation_id) do
    Repo.exists?(
      from a in CashAllocation,
        where: a.payment_operation_id == ^payment_operation_id and a.transferred
    )
  end

  @doc """
  The cash of one payment still held, per group, ordered by partner group identifier.

  Groups holding none of it are left out, so once a payment holds nothing anywhere the list is
  empty.
  """
  def held_by_group(payment_operation_id) do
    Repo.all(
      from a in CashAllocation,
        join: g in Group,
        on: g.id == a.group_id,
        where: a.payment_operation_id == ^payment_operation_id,
        where: a.status == ^CashAllocation.held(),
        group_by: g.group_id,
        order_by: [asc: g.group_id],
        select: %{group_id: g.group_id, amount_cents: sum(a.amount_cents)}
    )
  end

  @doc """
  Cash across every group, keyed by disposition.
  """
  def cash_totals do
    from(a in CashAllocation, group_by: a.status, select: {a.status, sum(a.amount_cents)})
    |> Repo.all()
    |> Map.new()
  end

  ## Keeping the group's totals in step

  @doc """
  Recomputes what each room holds and what the group's active rooms add up to.

  The group's stored totals are a projection of its rooms, so every operation that moves funding
  or cancels a room refreshes them before it reports an outcome.
  """
  def refresh(%Group{} = group) do
    held = held_by_room(group)
    applied = applied_by_room(group)

    rooms =
      for room <- rooms(group) do
        room = %{
          room
          | cash_paid_cents: Map.get(held, room.id, 0),
            credit_paid_cents: Map.get(applied, room.id, 0)
        }

        Repo.update_all(from(r in Room, where: r.id == ^room.id),
          set: [cash_paid_cents: room.cash_paid_cents, credit_paid_cents: room.credit_paid_cents]
        )

        room
      end

    active = Enum.filter(rooms, &Room.active?/1)

    Repo.update_all(from(g in Group, where: g.id == ^group.id),
      set: [
        lodging_total_cents: sum_by(active, & &1.lodging_cents),
        deposit_due_cents: sum_by(active, & &1.deposit_cents),
        cash_paid_cents: sum_by(active, & &1.cash_paid_cents),
        credit_paid_cents: sum_by(active, & &1.credit_paid_cents)
      ]
    )

    :ok
  end

  defp held_by_room(group) do
    from(a in CashAllocation,
      where: a.group_id == ^group.id and a.status == ^CashAllocation.held(),
      group_by: a.room_id,
      select: {a.room_id, sum(a.amount_cents)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp applied_by_room(group) do
    from(a in CreditApplication,
      where: a.group_id == ^group.id and a.status == "applied",
      group_by: a.room_id,
      select: {a.room_id, sum(a.amount_cents)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp sum_by(rooms, fun), do: Enum.sum(Enum.map(rooms, fun))

  ## Shared queries

  defp held_allocations(room_ids) do
    Repo.all(
      from a in CashAllocation,
        where: a.room_id in ^room_ids and a.status == ^CashAllocation.held(),
        order_by: [asc: a.id]
    )
  end

  defp applied_credit(room_ids) do
    Repo.all(
      from a in CreditApplication,
        where: a.room_id in ^room_ids and a.status == "applied",
        order_by: [asc: a.id]
    )
  end

  defp from_payment(payment_operation_id, statuses) do
    from a in CashAllocation,
      where: a.payment_operation_id == ^payment_operation_id and a.status in ^statuses
  end

  defp sum_cents(queryable), do: Repo.aggregate(queryable, :sum, :amount_cents) || 0

  defp total_cents(allocations), do: Enum.sum(Enum.map(allocations, & &1.amount_cents))

  defp reclassify([], _status, _lot), do: :ok

  defp reclassify(allocations, status, lot) do
    ids = Enum.map(allocations, & &1.id)
    changes = [status: status]
    changes = if lot, do: Keyword.put(changes, :converted_lot_id, lot.id), else: changes

    Repo.update_all(from(a in CashAllocation, where: a.id in ^ids), set: changes)
    :ok
  end

  # A reduction can stop part way through an allocation, which then splits: the part that leaves
  # takes the new status, and the part that stays keeps funding its room. Returns the groups the
  # cash was taken from.
  defp take_cents(allocations, amount_cents, status, posting),
    do: take_cents(allocations, amount_cents, status, posting, [])

  defp take_cents(_allocations, 0, _status, _posting, from), do: Enum.uniq(Enum.reverse(from))

  defp take_cents([], _amount_cents, _status, _posting, from),
    do: Enum.uniq(Enum.reverse(from))

  defp take_cents([allocation | rest], amount_cents, status, posting, taken_from) do
    taken = min(allocation.amount_cents, amount_cents)

    Finance.record_cash(posting, property_of(allocation), status, taken)

    if taken == allocation.amount_cents do
      reclassify([allocation], status, nil)
    else
      allocation
      |> Changeset.change(amount_cents: allocation.amount_cents - taken)
      |> Repo.update!()

      # The split keeps everything the allocation carried, so what leaves is still recognisable as
      # the same payment's cash and still sits where that cash sat.
      Repo.insert!(%CashAllocation{
        group_id: allocation.group_id,
        room_id: allocation.room_id,
        payment_operation_id: allocation.payment_operation_id,
        amount_cents: taken,
        status: status,
        allocation_seq: allocation.allocation_seq,
        transferred: allocation.transferred
      })
    end

    take_cents(rest, amount_cents - taken, status, posting, [allocation.group_id | taken_from])
  end

  # Held cash sits at the property of the group holding it, which a transfer may have made a
  # different property from the one the payment was recorded at.
  defp property_of(%CashAllocation{group_id: group_id}),
    do: Repo.one(from g in Group, where: g.id == ^group_id, select: g.property_id)
end
