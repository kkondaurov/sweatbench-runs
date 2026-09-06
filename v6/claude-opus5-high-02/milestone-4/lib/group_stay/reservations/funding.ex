defmodule GroupStay.Reservations.Funding do
  @moduledoc """
  Room-level accounting for the cash and hotel credit that fund a group's deposit.

  Funding fills the deposits of active rooms in the rooms' original order, one room at a time, in
  the order the funding operations are processed. Every allocation remembers the payment or credit
  lot it came from, so a room can be settled, a payment reduced, or a payment charged back without
  disturbing the rest of the group.

  Every function here runs inside the transaction of the operation that called it.
  """

  import Ecto.Query

  alias Ecto.Changeset
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
        status: CashAllocation.held()
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

    {status, lot, credit_issued_cents} =
      settle_cash(group, refund_method, refundable?, cash_cents, operation)

    reclassify(allocations, status, lot)
    settle_credit(room_ids, refundable?, operation.occurred_on)
    cancel_rooms(room_ids)

    %{
      refunded_cents: if(status == "refunded", do: cash_cents, else: 0),
      retained_cents: if(status == "retained", do: cash_cents, else: 0),
      credit_issued_cents: credit_issued_cents
    }
  end

  # Hotel credit is only offered where a refund is, and the whole settlement earns one bonus.
  defp settle_cash(group, "hotel_credit", true, cash_cents, operation) do
    {lot, credit_issued_cents} =
      Credit.issue(group, cash_cents, operation.operation_id, operation.occurred_on)

    {"converted", lot, credit_issued_cents}
  end

  defp settle_cash(_group, _refund_method, true, _cash_cents, _operation),
    do: {"refunded", nil, 0}

  defp settle_cash(_group, _refund_method, false, _cash_cents, _operation),
    do: {"retained", nil, 0}

  # Credit that funded a room goes back to the lot it came from when the guest is still entitled
  # to a refund, and is kept by the hotel when they are not.
  defp settle_credit(room_ids, true, on), do: Credit.restore(applied_credit(room_ids), on)
  defp settle_credit(room_ids, false, _on), do: Credit.consume(applied_credit(room_ids))

  defp cancel_rooms(room_ids) do
    Repo.update_all(from(r in Room, where: r.id in ^room_ids), set: [status: "cancelled"])
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
  Removes `amount_cents` of a payment's held cash, latest-filled room first.

  The room's deposit reopens by the amount removed; nothing that has already been settled moves.
  """
  def reduce(payment_operation_id, amount_cents) do
    payment_operation_id
    |> from_payment([CashAllocation.held()])
    |> order_by([a], desc: a.id)
    |> Repo.all()
    |> take_cents(amount_cents, "reduced")

    :ok
  end

  @doc """
  Reverses every remaining disposition of a payment and returns the cash it reclassified.

  Held cash leaves the rooms it funded, reopening their deposit. Cash already refunded or retained
  only changes its classification: the money itself moved long ago. Converted cash also revokes
  the credit entitlement it bought.
  """
  def charge_back(payment_operation_id) do
    allocations =
      payment_operation_id
      |> from_payment(CashAllocation.reversible_statuses())
      |> order_by([a], desc: a.id)
      |> Repo.all()

    revoke_entitlements(payment_operation_id, allocations)
    reclassify(allocations, "charged_back", nil)
    total_cents(allocations)
  end

  # Cash converted into a lot bought a share of it, so charging that cash back takes that share
  # out of the lot again. The share is calculated per lot, in the order the cash funded the rooms.
  defp revoke_entitlements(payment_operation_id, allocations) do
    allocations
    |> Enum.filter(& &1.converted_lot_id)
    |> Enum.map(& &1.converted_lot_id)
    |> Enum.uniq()
    |> Enum.each(&Credit.claw_back(&1, entitlement_cents(&1, payment_operation_id)))
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
      order_by: [asc: a.id],
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
  # takes the new status, and the part that stays keeps funding its room.
  defp take_cents(_allocations, 0, _status), do: :ok

  defp take_cents([allocation | rest], amount_cents, status) do
    taken = min(allocation.amount_cents, amount_cents)

    if taken == allocation.amount_cents do
      reclassify([allocation], status, nil)
    else
      allocation
      |> Changeset.change(amount_cents: allocation.amount_cents - taken)
      |> Repo.update!()

      Repo.insert!(%CashAllocation{
        group_id: allocation.group_id,
        room_id: allocation.room_id,
        payment_operation_id: allocation.payment_operation_id,
        amount_cents: taken,
        status: status
      })
    end

    take_cents(rest, amount_cents - taken, status)
  end
end
