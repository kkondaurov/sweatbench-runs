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

  A transfer moves held funding from one group's active rooms to another's
  without settling or revaluing it. The moved rows keep the payment or the lot
  they came from, so a later correction still follows a payment's cash wherever
  that cash now funds rooms.
  """

  import Ecto.Query

  alias GroupStay.Credit
  alias GroupStay.Finance
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
  def allocate_cash(%Group{} = group, operation_id, amount_cents, posting) do
    :ok = Finance.cash(posting, group.property_id, "received", amount_cents)

    place(group, [{provenance("cash", operation_id, nil), amount_cents}])
  end

  @doc """
  Allocates credit across the group's active room deposits.

  `slices` are `{lot, amount_cents}` pairs in the order the lots were consumed,
  so each room records which lot paid for it.
  """
  def allocate_credit(%Group{} = group, operation_id, slices) do
    place(
      group,
      Enum.map(slices, fn {lot, cents} ->
        {provenance("credit", operation_id, lot.id), cents}
      end)
    )
  end

  # Where one slice of funding came from, and whether it got here by transfer.
  defp provenance(kind, operation_id, lot_ref, transferred \\ false),
    do: %{kind: kind, operation_id: operation_id, lot_ref: lot_ref, transferred: transferred}

  # Fills the group's unfunded active-room capacity with `slices`, taking the
  # rooms in their original order and the slices in the order they arrive. One
  # row is written per {room, slice} pair, so every room records where its
  # funding came from.
  defp place(group, slices) do
    rooms = active_rooms(group)
    held = held_by_room(group)
    capacities = Enum.map(rooms, &(&1.deposit_cents - Map.get(held, &1.id, 0)))
    {placements, 0} = Plan.fill(capacities, sum_of(slices, &elem(&1, 1)))

    for {index, provenance, amount_cents} <- merge(placements, slices) do
      insert!(%{
        group_ref: group.id,
        room_ref: Enum.fetch!(rooms, index).id,
        kind: provenance.kind,
        operation_id: provenance.operation_id,
        lot_ref: provenance.lot_ref,
        amount_cents: amount_cents,
        disposition: @held,
        transferred: provenance.transferred
      })
    end

    :ok
  end

  # Walks the room placements and the funding slices together, so one row is
  # written for every {room, source} pair the funding touches.
  defp merge([], []), do: []

  defp merge([{index, room_left} | placements], [{provenance, slice_left} | slices]) do
    taken = min(room_left, slice_left)

    [
      {index, provenance, taken}
      | merge(
          requeue({index, room_left - taken}, placements),
          requeue({provenance, slice_left - taken}, slices)
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

  @doc """
  Cash and hotel credit currently allocated to the group's active rooms.

  This is the funding a transfer can move: settled funding has left, and unpaid
  deposit was never funding at all.
  """
  def held_funding_cents(%Group{} = group) do
    Repo.one(from a in held_funding(group), select: sum(a.amount_cents)) || 0
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

  @doc """
  True once any of one payment's cash has been moved between groups.

  A transfer marks every row it creates, and those rows outlive the funding they
  carried, so a payment never forgets that its cash has moved.
  """
  def transferred?(payment_operation_id) do
    Repo.exists?(
      from a in Allocation,
        where: a.kind == "cash",
        where: a.operation_id == ^payment_operation_id,
        where: a.transferred
    )
  end

  @doc """
  Cash from one payment that is still held, by the group now holding it.

  Groups holding none of it are left out, and the amounts add up to the
  payment's held cash.
  """
  def held_cash_by_group(payment_operation_id) do
    Repo.all(
      from a in Allocation,
        join: g in Group,
        on: g.id == a.group_ref,
        where: a.kind == "cash",
        where: a.operation_id == ^payment_operation_id,
        where: a.disposition == @held,
        group_by: g.group_id,
        order_by: [asc: g.group_id],
        select: %{group_id: g.group_id, amount_cents: sum(a.amount_cents)}
    )
  end

  @doc """
  Held cash by the property whose rooms it funds.

  This is the position each property carries into the reporting window when
  finance reporting starts.
  """
  def held_cash_by_property do
    Repo.all(
      from a in Allocation,
        join: g in Group,
        on: g.id == a.group_ref,
        where: a.kind == "cash",
        where: a.disposition == @held,
        group_by: g.property_id,
        order_by: [asc: g.property_id],
        select: {g.property_id, sum(a.amount_cents)}
    )
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

  `opts` carries `:refundable?`, `:refund_method`, `:operation_id`,
  `:occurred_on` and the `:posting` its finance effects report on. The
  hotel-credit bonus is taken once on the rooms' combined cash. Returns the
  settlement totals.
  """
  def settle_rooms(%Group{} = group, rooms, opts) do
    room_refs = Enum.map(rooms, & &1.id)
    credit_rows = held_rows(room_refs, "credit")
    cash_rows = held_rows(room_refs, "cash")
    cash_cents = sum_of(cash_rows, & &1.amount_cents)

    settle_credit(credit_rows, opts.refundable?, opts.posting)

    settlement = settle(opts.refundable?, opts.refund_method, cash_cents)

    issued_lot = issue_lot(group, settlement, opts)

    for row <- cash_rows do
      set_disposition(row, settlement.disposition, issued_lot && issued_lot.id)
    end

    :ok =
      Finance.cash(
        opts.posting,
        group.property_id,
        settlement.classification,
        cash_cents
      )

    settlement
  end

  # A refundable settlement hands applied credit back to its own lot; a
  # non-refundable one consumes it along with the cash.
  defp settle_credit(rows, true, posting) do
    for row <- rows do
      :ok = Credit.restore(row.lot_ref, row.amount_cents, posting)
      set_disposition(row, "restored")
    end
  end

  defp settle_credit(rows, false, posting) do
    for row <- rows do
      :ok = Finance.credit_consumed(posting, row.lot_ref, row.amount_cents)
      set_disposition(row, "consumed")
    end
  end

  defp settle(false, _refund_method, cash_cents) do
    %{
      disposition: "retained",
      classification: "retained",
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
      classification: "converted_to_credit",
      refunded_cents: 0,
      retained_cents: 0,
      converted_cents: cash_cents,
      credit_issued_cents: Pricing.credit_value_cents(cash_cents)
    }
  end

  defp settle(true, "cash", cash_cents) do
    %{
      disposition: "refunded",
      classification: "refunded",
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
        opts.occurred_on,
        opts.posting
      )

    lot
  end

  # --- transferring -------------------------------------------------------

  @doc """
  Moves `amount_cents` of held funding from one group's active rooms to another's.

  Funding leaves the source in reverse allocation order, the most recently
  created allocation first, whatever kind it is, and fills the destination's
  active rooms in their original order in the order it was drawn. Nothing is
  settled or revalued: each moved unit keeps its kind and either the payment or
  the lot it came from.
  """
  def transfer(%Group{} = source, %Group{} = destination, amount_cents, posting) do
    slices = draw(source, amount_cents)
    cash_cents = Enum.sum(for {%{kind: "cash"}, cents} <- slices, do: cents)

    :ok = Finance.cash(posting, source.property_id, "transferred_out", cash_cents)
    :ok = Finance.cash(posting, destination.property_id, "transferred_in", cash_cents)

    place(destination, slices)
  end

  defp draw(group, amount_cents) do
    group
    |> held_funding()
    |> order_by([a], desc: a.id)
    |> Repo.all()
    |> take(amount_cents)
  end

  defp take(_rows, 0), do: []

  defp take([row | rest], amount_cents) do
    taken = min(row.amount_cents, amount_cents)

    if taken == row.amount_cents do
      Repo.delete!(row)
    else
      {:ok, _row} = update_row(row, %{amount_cents: row.amount_cents - taken})
    end

    [{moved(row), taken} | take(rest, amount_cents - taken)]
  end

  # A moved unit keeps the provenance of the row it left and is marked as
  # transferred, which is how a payment remembers that its cash has moved.
  defp moved(row), do: provenance(row.kind, row.operation_id, row.lot_ref, true)

  # --- correcting ---------------------------------------------------------

  @doc "Cash from one payment that is still held on an active room."
  def held_cash_cents(payment_operation_id) do
    payment_operation_id
    |> cash_by_disposition()
    |> Map.get(@held, 0)
  end

  @doc """
  Takes `amount_cents` of one payment's held cash back off the rooms it funds.

  Allocations are removed in reverse fill order across every group the payment
  funds, so the deposit reopens on the rooms the payment filled last. Returns
  the groups whose funding changed.
  """
  def reduce_cash(payment_operation_id, amount_cents, posting) do
    removals =
      payment_operation_id
      |> payment_rows([@held])
      |> Enum.reverse()
      |> detach(amount_cents, "reduced")

    properties = properties_by_group_ref(Enum.map(removals, &elem(&1, 0)))

    for {group_ref, taken} <- removals do
      :ok = Finance.cash(posting, Map.fetch!(properties, group_ref), "reduced", taken)
    end

    Enum.map(removals, &elem(&1, 0))
  end

  defp detach(_rows, 0, _disposition), do: []

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
        disposition: disposition,
        transferred: row.transferred
      })
    end

    [{row.group_ref, taken} | detach(rest, amount_cents - taken, disposition)]
  end

  @doc """
  Reverses every remaining disposition of one payment's cash.

  Held cash leaves the rooms it funds, in every group it reaches; cash already
  refunded to the guest or retained by the hotel is reclassified without being
  reissued; converted cash loses the credit entitlement it bought. Cash already
  recorded as reduced is settled history and is left alone. Returns the reversed
  amount and the groups whose funding changed.
  """
  def charge_back(payment_operation_id, posting) do
    rows = payment_rows(payment_operation_id, Allocation.chargeable())

    rows
    |> Enum.map(& &1.issued_lot_ref)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(&Credit.claw_back(&1, entitlement_cents(&1, payment_operation_id), posting))

    properties = properties_by_group_ref(Enum.map(rows, & &1.group_ref))

    for row <- rows do
      post_chargeback(row, Map.fetch!(properties, row.group_ref), posting)
      set_disposition(row, "charged_back")
    end

    {sum_of(rows, & &1.amount_cents), Enum.map(rows, & &1.group_ref)}
  end

  # Every reversed cent arrives as charged back. Held cash simply leaves the
  # rooms it funded, but cash a cancellation had already settled leaves a
  # settlement that is no longer true, so that settlement is posted back out of
  # the property that made it.
  defp post_chargeback(row, property_id, posting) do
    :ok = Finance.cash(posting, property_id, "charged_back", row.amount_cents)

    case reversed_settlement(row.disposition) do
      nil -> :ok
      classification -> Finance.cash(posting, property_id, classification, -row.amount_cents)
    end
  end

  defp reversed_settlement("held"), do: nil
  defp reversed_settlement("refunded"), do: "refunded"
  defp reversed_settlement("retained"), do: "retained"
  defp reversed_settlement("converted"), do: "converted_to_credit"

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

  defp properties_by_group_ref(group_refs) do
    Repo.all(
      from g in Group,
        where: g.id in ^Enum.uniq(group_refs),
        select: {g.id, g.property_id}
    )
    |> Map.new()
  end

  defp payment_rows(payment_operation_id, dispositions) do
    Repo.all(
      from a in Allocation,
        where: a.kind == "cash",
        where: a.operation_id == ^payment_operation_id,
        where: a.disposition in ^dispositions,
        order_by: [asc: a.id]
    )
  end

  # Funding still standing on the group's active rooms, which is the only funding
  # a transfer can move.
  defp held_funding(group) do
    from a in Allocation,
      join: r in Room,
      on: r.id == a.room_ref,
      where: a.group_ref == ^group.id,
      where: a.disposition == @held,
      where: r.status == "active"
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
