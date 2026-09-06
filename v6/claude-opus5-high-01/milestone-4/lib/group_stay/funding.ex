defmodule GroupStay.Funding do
  @moduledoc """
  Room-level accounting for the cash and hotel credit that fund a group deposit.

  Every funding operation is allocated to the group's active rooms in their
  original order, one room's deposit at a time, and the allocation rows are
  inserted in funding order. Their primary key is therefore also the fill order
  that a reduction or a chargeback unwinds from the end.

  A cancellation settles the allocations of the rooms it cancels: cash is
  refunded, retained, or converted to credit, and credit either returns to its
  lot or is consumed.
  """

  import Ecto.Query

  alias GroupStay.Credit
  alias GroupStay.Funding.Allocation
  alias GroupStay.Funding.Plan
  alias GroupStay.Pricing
  alias GroupStay.Repo
  alias GroupStay.Reservations.Group
  alias GroupStay.Reservations.Room

  @held "held"

  # Funding a reduction or a chargeback took back is no longer the room's.
  @detached ~w(reduced charged_back)

  # --- allocating ---------------------------------------------------------

  @doc "Allocates one payment's cash across the group's active room deposits."
  def allocate_cash(%Group{} = group, operation_id, amount_cents),
    do: allocate(group, "cash", operation_id, [{nil, amount_cents}])

  @doc """
  Allocates credit across the group's active room deposits.

  `slices` are `{lot, amount_cents}` pairs in the order the lots were consumed,
  so each room records which lot paid for it.
  """
  def allocate_credit(%Group{} = group, operation_id, slices) do
    allocate(
      group,
      "credit",
      operation_id,
      Enum.map(slices, fn {lot, cents} -> {lot.id, cents} end)
    )
  end

  defp allocate(group, kind, operation_id, slices) do
    rooms = active_rooms(group)
    held = held_by_room(group)
    capacities = Enum.map(rooms, &(&1.deposit_cents - Map.get(held, &1.id, 0)))
    {placements, 0} = Plan.fill(capacities, sum_of(slices, &elem(&1, 1)))

    for {index, lot_ref, amount_cents} <- merge(placements, slices) do
      insert!(%{
        group_ref: group.id,
        room_ref: Enum.fetch!(rooms, index).id,
        kind: kind,
        operation_id: operation_id,
        lot_ref: lot_ref,
        amount_cents: amount_cents,
        disposition: @held
      })
    end

    :ok
  end

  # Walks the room placements and the funding slices together, so one row is
  # written for every {room, source} pair the funding touches.
  defp merge([], []), do: []

  defp merge([{index, room_left} | placements], [{lot_ref, slice_left} | slices]) do
    taken = min(room_left, slice_left)

    [
      {index, lot_ref, taken}
      | merge(
          requeue({index, room_left - taken}, placements),
          requeue({lot_ref, slice_left - taken}, slices)
        )
    ]
  end

  defp requeue({_source, 0}, rest), do: rest
  defp requeue(entry, rest), do: [entry | rest]

  # --- reading ------------------------------------------------------------

  @doc "The group's rooms that have not been cancelled, in their original order."
  def active_rooms(%Group{} = group) do
    Repo.all(
      from r in Room,
        where: r.group_ref == ^group.id,
        where: r.status == "active",
        order_by: [asc: r.position]
    )
  end

  @doc """
  The group's lodging, deposit and funding totals over its active rooms.

  Cancelled rooms no longer owe a deposit and no longer hold funding, so they
  leave every one of these totals.
  """
  def group_totals(%Group{} = group) do
    rooms = active_rooms(group)
    held = held_by_room_and_kind(group)

    %{
      lodging_total_cents: sum_of(rooms, & &1.lodging_cents),
      deposit_due_cents: sum_of(rooms, & &1.deposit_cents),
      cash_paid_cents: sum_kind(rooms, held, "cash"),
      credit_paid_cents: sum_kind(rooms, held, "credit")
    }
  end

  @doc """
  Fills in `cash_paid_cents` and `credit_paid_cents` on each of the group's rooms.

  A room reports the funding still attributed to it. Cash a reduction or a
  chargeback took back is no longer the room's; cash and credit a cancellation
  settled stay on the room they paid for.
  """
  def with_room_funding(%Group{} = group) do
    attributed = attributed_by_room_and_kind(group)

    rooms =
      Enum.map(group.rooms, fn room ->
        %{
          room
          | cash_paid_cents: Map.get(attributed, {room.id, "cash"}, 0),
            credit_paid_cents: Map.get(attributed, {room.id, "credit"}, 0)
        }
      end)

    %{group | rooms: rooms}
  end

  @doc "Cash from one payment, summed by where that cash currently stands."
  def cash_by_disposition(payment_operation_id) do
    Repo.all(
      from a in Allocation,
        where: a.kind == "cash",
        where: a.operation_id == ^payment_operation_id,
        group_by: a.disposition,
        select: {a.disposition, sum(a.amount_cents)}
    )
    |> Map.new()
  end

  @doc "All recorded cash, summed by where it currently stands."
  def cash_totals do
    Repo.all(
      from a in Allocation,
        where: a.kind == "cash",
        group_by: a.disposition,
        select: {a.disposition, sum(a.amount_cents)}
    )
    |> Map.new()
  end

  # --- settling -----------------------------------------------------------

  @doc """
  Settles the cash and credit held by `rooms`.

  `opts` carries `:refundable?`, `:refund_method`, `:operation_id` and
  `:occurred_on`. The hotel-credit bonus is taken once on the rooms' combined
  cash. Returns the settlement totals.
  """
  def settle_rooms(%Group{} = group, rooms, opts) do
    room_refs = Enum.map(rooms, & &1.id)
    credit_rows = held_rows(room_refs, "credit")
    cash_rows = held_rows(room_refs, "cash")

    settle_credit(credit_rows, opts.refundable?)

    settlement =
      settle(opts.refundable?, opts.refund_method, sum_of(cash_rows, & &1.amount_cents))

    issued_lot = issue_lot(group, settlement, opts)

    for row <- cash_rows do
      set_disposition(row, settlement.disposition, issued_lot && issued_lot.id)
    end

    settlement
  end

  # A refundable settlement hands applied credit back to its own lot; a
  # non-refundable one consumes it along with the cash.
  defp settle_credit(rows, true) do
    for row <- rows do
      :ok = Credit.restore(row.lot_ref, row.amount_cents)
      set_disposition(row, "restored")
    end
  end

  defp settle_credit(rows, false) do
    for row <- rows, do: set_disposition(row, "consumed")
  end

  defp settle(false, _refund_method, cash_cents) do
    %{
      disposition: "retained",
      refunded_cents: 0,
      retained_cents: cash_cents,
      converted_cents: 0,
      credit_issued_cents: 0
    }
  end

  defp settle(true, "hotel_credit", cash_cents) do
    # The cash is neither refunded nor retained: it leaves as credit worth 110%.
    %{
      disposition: "converted",
      refunded_cents: 0,
      retained_cents: 0,
      converted_cents: cash_cents,
      credit_issued_cents: Pricing.credit_value_cents(cash_cents)
    }
  end

  defp settle(true, "cash", cash_cents) do
    %{
      disposition: "refunded",
      refunded_cents: cash_cents,
      retained_cents: 0,
      converted_cents: 0,
      credit_issued_cents: 0
    }
  end

  defp issue_lot(_group, %{credit_issued_cents: 0}, _opts), do: nil

  defp issue_lot(group, settlement, opts) do
    {:ok, lot} =
      Credit.issue_lot(
        group.guest_id,
        opts.operation_id,
        settlement.credit_issued_cents,
        opts.occurred_on
      )

    lot
  end

  # --- correcting ---------------------------------------------------------

  @doc "Cash from one payment that is still held on an active room."
  def held_cash_cents(payment_operation_id) do
    payment_operation_id
    |> cash_by_disposition()
    |> Map.get(@held, 0)
  end

  @doc """
  Takes `amount_cents` of one payment's held cash back off the rooms it funds.

  Allocations are removed in reverse fill order, so the deposit reopens on the
  rooms the payment filled last.
  """
  def reduce_cash(payment_operation_id, amount_cents) do
    payment_operation_id
    |> payment_rows([@held])
    |> Enum.reverse()
    |> detach(amount_cents, "reduced")
  end

  defp detach(_rows, 0, _disposition), do: :ok

  defp detach([row | rest], amount_cents, disposition) do
    taken = min(row.amount_cents, amount_cents)

    if taken == row.amount_cents do
      set_disposition(row, disposition)
    else
      {:ok, _row} = update_row(row, %{amount_cents: row.amount_cents - taken})

      insert!(%{
        group_ref: row.group_ref,
        room_ref: row.room_ref,
        kind: row.kind,
        operation_id: row.operation_id,
        lot_ref: row.lot_ref,
        issued_lot_ref: row.issued_lot_ref,
        amount_cents: taken,
        disposition: disposition
      })
    end

    detach(rest, amount_cents - taken, disposition)
  end

  @doc """
  Reverses every remaining disposition of one payment's cash.

  Held cash leaves the rooms it funds; cash already refunded to the guest or
  retained by the hotel is reclassified without being reissued; converted cash
  loses the credit entitlement it bought. Cash already recorded as reduced is
  settled history and is left alone. Returns the reversed amount.
  """
  def charge_back(payment_operation_id) do
    rows = payment_rows(payment_operation_id, Allocation.chargeable())

    rows
    |> Enum.map(& &1.issued_lot_ref)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(&Credit.claw_back(&1, entitlement_cents(&1, payment_operation_id)))

    for row <- rows, do: set_disposition(row, "charged_back")

    sum_of(rows, & &1.amount_cents)
  end

  @doc """
  The share of a credit lot one payment paid for.

  Every payment that funded the lot is taken in the funding order room
  accounting uses, with the unattributed senior block first. A payment's share is
  the credit value of the settled cash through it minus the credit value through
  the payment before it, so the shares telescope exactly to the issued lot.
  """
  def entitlement_cents(lot_ref, payment_operation_id) do
    {_settled, entitlement} =
      lot_ref
      |> contributions()
      |> Enum.reduce({0, 0}, fn {source, cash_cents}, {settled, entitlement} ->
        share =
          Pricing.credit_value_cents(settled + cash_cents) -
            Pricing.credit_value_cents(settled)

        {settled + cash_cents,
         if(source == payment_operation_id, do: entitlement + share, else: entitlement)}
      end)

    entitlement
  end

  # The cash each source put into one lot, in funding order.
  defp contributions(lot_ref) do
    Repo.all(
      from a in Allocation,
        where: a.issued_lot_ref == ^lot_ref,
        order_by: [asc: a.id],
        select: {a.operation_id, a.amount_cents}
    )
    |> Enum.reduce([], fn {source, cash_cents}, acc ->
      case List.keyfind(acc, source, 0) do
        nil -> acc ++ [{source, cash_cents}]
        {^source, total} -> List.keyreplace(acc, source, 0, {source, total + cash_cents})
      end
    end)
  end

  # --- internals ----------------------------------------------------------

  defp payment_rows(payment_operation_id, dispositions) do
    Repo.all(
      from a in Allocation,
        where: a.kind == "cash",
        where: a.operation_id == ^payment_operation_id,
        where: a.disposition in ^dispositions,
        order_by: [asc: a.id]
    )
  end

  defp held_rows(room_refs, kind) do
    Repo.all(
      from a in Allocation,
        where: a.room_ref in ^room_refs,
        where: a.kind == ^kind,
        where: a.disposition == @held,
        order_by: [asc: a.id]
    )
  end

  defp held_by_room(group) do
    Repo.all(
      from a in Allocation,
        where: a.group_ref == ^group.id,
        where: a.disposition == @held,
        group_by: a.room_ref,
        select: {a.room_ref, sum(a.amount_cents)}
    )
    |> Map.new()
  end

  defp held_by_room_and_kind(group) do
    Repo.all(
      from a in Allocation,
        where: a.group_ref == ^group.id,
        where: a.disposition == @held,
        group_by: [a.room_ref, a.kind],
        select: {{a.room_ref, a.kind}, sum(a.amount_cents)}
    )
    |> Map.new()
  end

  defp attributed_by_room_and_kind(group) do
    Repo.all(
      from a in Allocation,
        where: a.group_ref == ^group.id,
        where: a.disposition not in @detached,
        group_by: [a.room_ref, a.kind],
        select: {{a.room_ref, a.kind}, sum(a.amount_cents)}
    )
    |> Map.new()
  end

  defp sum_kind(rooms, sums, kind),
    do: sum_of(rooms, &Map.get(sums, {&1.id, kind}, 0))

  # Converted cash keeps its link to the lot it bought even once it is charged
  # back, so the entitlements of the other payments in that lot still telescope.
  defp set_disposition(row, disposition, issued_lot_ref \\ nil) do
    {:ok, _row} =
      update_row(row, %{
        disposition: disposition,
        issued_lot_ref: issued_lot_ref || row.issued_lot_ref
      })
  end

  defp update_row(row, attrs) do
    row
    |> Allocation.changeset(attrs)
    |> Repo.update()
  end

  defp insert!(attrs) do
    %Allocation{}
    |> Allocation.changeset(attrs)
    |> Repo.insert!()
  end

  defp sum_of(enumerable, fun), do: enumerable |> Enum.map(fun) |> Enum.sum()
end
