defmodule GroupStay.Accounting do
  @moduledoc """
  Room accounting: how cash and hotel credit fund the active rooms' deposits.

  Cash and credit fund active room deposits in the rooms' original order,
  filling one room's deposit before moving to the next. Each funding event
  (an applied cash payment or hotel-credit application) allocates in
  operation-processing order, recorded as `GroupStay.Groups.Allocation` rows
  whose integer primary key preserves fill order.

  Funding without a durable operation identity (funding from before durable
  operation records existed) is one unattributed senior block per group: its
  ledger entries carry no `operation_key`, and any settlement it takes part
  in records one unattributed disposition.

  Settlement (full or selected-room cancellation) settles the rooms'
  allocations: cash moves to refunded, retained, or converted dispositions
  attributed to the originating payment entries; credit is restored to its
  original lot (absorbing any unrecovered clawback first) or consumed.
  Reductions remove held cash of one payment in reverse fill order, and
  chargebacks reverse all cash of one payment except any portion already
  reduced, reclassifying its dispositions and revoking the credit
  entitlement it created. Both follow a payment's allocations wherever they
  currently fund rooms, so their effects can span groups; every group whose
  funding they change is reported back so its revision can advance.

  Deposit transfers move held funding between two active groups of the same
  guest without settling or revaluing anything: units are drawn from the
  source's active-room allocations in reverse allocation order and fill the
  destination's active rooms in their original order, keeping each unit's
  provenance (the payment identity for cash, the original lot for credit).
  """

  alias GroupStay.Credit
  alias GroupStay.Credit.Application
  alias GroupStay.Credit.Entitlement
  alias GroupStay.Credit.Lot
  alias GroupStay.Groups
  alias GroupStay.Groups.Allocation
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Ledger
  alias GroupStay.Ledger.Entry
  alias GroupStay.Repo

  import Ecto.Query

  ## Reads

  @doc "The group's active rooms in their original order."
  def active_rooms(%Group{} = group) do
    Enum.filter(group.rooms, &(&1.status == "active"))
  end

  @doc "Cash currently held across all groups (the ledger's held cash)."
  def held_cash_cents do
    from(a in Allocation,
      where: a.kind == "cash" and a.remaining_cents > 0,
      select: coalesce(sum(a.remaining_cents), 0)
    )
    |> Repo.one()
  end

  @doc "Cash currently held on one payment's allocations."
  def payment_held_cents(payment_entry_pk) do
    from(a in Allocation,
      where: a.payment_entry_id == ^payment_entry_pk and a.remaining_cents > 0,
      select: coalesce(sum(a.remaining_cents), 0)
    )
    |> Repo.one()
  end

  @doc """
  Held cash from one payment grouped by the group whose rooms currently hold
  it, ordered by the partner `group_id`. Groups holding none of the payment's
  cash are omitted.
  """
  def payment_held_by_group(payment_entry_pk) do
    from(a in Allocation,
      join: g in assoc(a, :group),
      where: a.payment_entry_id == ^payment_entry_pk and a.remaining_cents > 0,
      group_by: g.group_id,
      order_by: g.group_id,
      select: {g.group_id, sum(a.remaining_cents)}
    )
    |> Repo.all()
    |> Enum.map(fn {group_id, amount_cents} ->
      %{"group_id" => group_id, "amount_cents" => amount_cents}
    end)
  end

  @doc "The cash or credit paid on a room so far: held plus settled allocations."
  def room_paid_cents(%Room{} = room, kind) do
    room.allocations
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.sum_by(&(&1.remaining_cents + &1.settled_cents))
  end

  ## Funding

  @doc """
  Allocates a cash payment's amount across the group's active room deposits,
  in the rooms' original order, filling one room's deposit before moving to
  the next.
  """
  def allocate_cash!(%Group{} = group, %Entry{} = payment_entry, amount_cents) do
    fill_rooms!(group, "cash", [{payment_entry, amount_cents}])
  end

  @doc """
  Allocates a hotel-credit application across the group's active room
  deposits. `applications` are the application rows created for the
  operation, in lot-consumption order; rooms fill in their original order.
  """
  def allocate_credit!(%Group{} = group, applications) do
    fill_rooms!(group, "credit", Enum.map(applications, &{&1, &1.amount_cents}))
  end

  defp fill_rooms!(%Group{} = group, kind, chunks) do
    {rooms, gaps} = room_gaps(group)

    {leftover, _gaps} =
      Enum.reduce(chunks, {0, gaps}, fn {ref, amount}, {leftover, gaps} ->
        {chunk_leftover, gaps} = fill_one_chunk!(group, rooms, gaps, kind, ref, amount)
        {leftover + chunk_leftover, gaps}
      end)

    if leftover != 0 do
      raise ArgumentError, "funding exceeds the active rooms' deposits"
    end

    :ok
  end

  # The group's active rooms and, for each, how much deposit it can still
  # absorb (its requirement minus what it currently holds).
  defp room_gaps(%Group{} = group) do
    rooms = active_rooms(group)

    held =
      from(a in Allocation,
        where: a.group_id == ^group.id and a.remaining_cents > 0,
        group_by: a.room_id,
        select: {a.room_id, sum(a.remaining_cents)}
      )
      |> Repo.all()
      |> Map.new()

    gaps =
      Map.new(rooms, fn room ->
        {room.id, Groups.room_deposit_cents(group, room) - Map.get(held, room.id, 0)}
      end)

    {rooms, gaps}
  end

  defp fill_one_chunk!(_group, _rooms, gaps, _kind, _ref, 0), do: {0, gaps}

  defp fill_one_chunk!(group, [room | rest], gaps, kind, ref, amount) do
    gap = Map.get(gaps, room.id, 0)

    if gap == 0 do
      fill_one_chunk!(group, rest, gaps, kind, ref, amount)
    else
      chunk = min(gap, amount)
      insert_allocation!(group, room, kind, ref, chunk)
      gaps = Map.put(gaps, room.id, gap - chunk)
      fill_one_chunk!(group, [room | rest], gaps, kind, ref, amount - chunk)
    end
  end

  defp fill_one_chunk!(_group, [], _gaps, _kind, _ref, amount), do: {amount, %{}}

  defp insert_allocation!(group, room, "cash", %Entry{} = entry, amount) do
    insert_allocation!(group, room, %{
      kind: "cash",
      payment_entry_id: entry.id,
      amount_cents: amount
    })
  end

  # Unattributed (legacy) cash keeps no payment identity when it moves.
  defp insert_allocation!(group, room, "cash", nil, amount) do
    insert_allocation!(group, room, %{kind: "cash", amount_cents: amount})
  end

  defp insert_allocation!(group, room, "credit", application, amount) do
    insert_allocation!(group, room, %{
      kind: "credit",
      credit_application_id: application.id,
      amount_cents: amount
    })
  end

  defp insert_allocation!(group, room, attrs) do
    %Allocation{}
    |> Allocation.changeset(
      Map.merge(attrs, %{
        group_id: group.id,
        room_id: room.id,
        remaining_cents: attrs[:amount_cents],
        settled_cents: 0
      })
    )
    |> Repo.insert!()

    :ok
  end

  ## Settlement

  @doc """
  Settles the given rooms' allocated cash and credit using the same date,
  policy, refund method, bonus, and restoration rules as a full cancellation.

  Cash settles to refunded, retained, or converted dispositions attributed to
  the originating payment entries (one unattributed disposition covers the
  unattributed block). With the hotel-credit refund method, one lot worth
  110% of the combined settled cash is issued, with per-payment entitlements
  assigned in funding order, the unattributed block first. Refundable
  settlements restore credit to its original lot, absorbing any unrecovered
  clawback before applying the lot's expiry; non-refundable settlements
  consume it.

  Returns `%{refunded_cents:, retained_cents:, credit_issued_cents:}`.
  """
  def settle_rooms!(group, rooms, refundable, refund_method, source_operation_id, occurred_on) do
    room_pks = Enum.map(rooms, & &1.id)

    cash_allocations = load_allocations(room_pks, "cash")
    credit_allocations = load_allocations(room_pks, "credit")

    cash_totals = settlement_cash_totals(cash_allocations)

    settle_cash_allocations!(cash_allocations)
    settle_credit_allocations!(credit_allocations, refundable, occurred_on)

    {refunded_cents, retained_cents, credit_issued_cents} =
      record_cash_dispositions!(
        group,
        cash_totals,
        refundable,
        refund_method,
        source_operation_id,
        occurred_on
      )

    for room <- rooms do
      room
      |> Ecto.Changeset.change(status: "cancelled")
      |> Repo.update!()
    end

    %{
      refunded_cents: refunded_cents,
      retained_cents: retained_cents,
      credit_issued_cents: credit_issued_cents
    }
  end

  defp load_allocations(room_pks, kind) do
    from(a in Allocation,
      where: a.room_id in ^room_pks and a.kind == ^kind and a.remaining_cents > 0,
      order_by: a.id,
      preload: [:payment_entry, credit_application: :lot]
    )
    |> Repo.all()
  end

  # Splits the settled cash into the unattributed block (funding without a
  # durable operation identity) and the recorded payments, in funding order.
  defp settlement_cash_totals(cash_allocations) do
    groups =
      cash_allocations
      |> Enum.group_by(& &1.payment_entry_id)
      |> Enum.map(fn {_entry_pk, allocations} -> {hd(allocations).payment_entry, allocations} end)

    {unattributed, recorded_groups} =
      Enum.split_with(groups, fn {entry, _allocations} -> is_nil(entry.operation_key) end)

    legacy_total =
      unattributed
      |> Enum.flat_map(fn {_entry, allocations} -> allocations end)
      |> Enum.sum_by(& &1.remaining_cents)

    recorded =
      recorded_groups
      |> Enum.map(fn {entry, allocations} ->
        {entry, Enum.sum_by(allocations, & &1.remaining_cents)}
      end)
      |> Enum.sort_by(fn {entry, _amount} -> payment_funding_order(cash_allocations, entry) end)

    %{legacy_total: legacy_total, recorded: recorded}
  end

  defp payment_funding_order(cash_allocations, entry) do
    cash_allocations
    |> Enum.filter(&(&1.payment_entry_id == entry.id))
    |> Enum.map(& &1.id)
    |> Enum.min()
  end

  defp settle_cash_allocations!(cash_allocations) do
    for allocation <- cash_allocations do
      allocation
      |> Ecto.Changeset.change(
        settled_cents: allocation.settled_cents + allocation.remaining_cents,
        remaining_cents: 0
      )
      |> Repo.update!()
    end

    :ok
  end

  defp settle_credit_allocations!(credit_allocations, refundable, occurred_on) do
    for allocation <- credit_allocations do
      allocation
      |> Ecto.Changeset.change(
        settled_cents: allocation.settled_cents + allocation.remaining_cents,
        remaining_cents: 0
      )
      |> Repo.update!()

      if refundable do
        Credit.restore_to_lot!(
          Repo.get!(Lot, allocation.credit_application.lot_id),
          allocation.remaining_cents,
          occurred_on
        )
      end
    end

    :ok
  end

  defp record_cash_dispositions!(
         group,
         %{legacy_total: legacy_total, recorded: recorded},
         refundable,
         refund_method,
         source_operation_id,
         occurred_on
       ) do
    total = legacy_total + Enum.sum_by(recorded, fn {_entry, amount} -> amount end)

    cond do
      refundable and refund_method == "hotel_credit" and total > 0 ->
        credit_issued = Credit.lot_value_cents(total)

        lot = Credit.issue_lot!(group.guest_id, source_operation_id, credit_issued, occurred_on)

        contributions =
          [{nil, legacy_total}] ++
            Enum.map(recorded, fn {entry, amount} -> {entry, amount} end)

        Credit.record_entitlements!(lot.id, contributions)

        for {entry, amount} <- recorded do
          Ledger.record_conversion!(group.id, amount, occurred_on, entry.id)
        end

        if legacy_total > 0 do
          Ledger.record_conversion!(group.id, legacy_total, occurred_on, nil)
        end

        {0, 0, credit_issued}

      refundable and refund_method == "hotel_credit" ->
        {0, 0, 0}

      refundable ->
        for {entry, amount} <- recorded do
          Ledger.record_refund!(group.id, amount, occurred_on, entry.id)
        end

        if legacy_total > 0 do
          Ledger.record_refund!(group.id, legacy_total, occurred_on, nil)
        end

        {total, 0, 0}

      true ->
        for {entry, amount} <- recorded do
          Ledger.record_retention!(group.id, amount, occurred_on, entry.id)
        end

        if legacy_total > 0 do
          Ledger.record_retention!(group.id, legacy_total, occurred_on, nil)
        end

        {0, total, 0}
    end
  end

  ## Transferring held funding

  @doc """
  Moves `amount_cents` of held funding from the source group's active rooms
  to the destination group's active rooms.

  Units are drawn from the source's active-room allocations in reverse
  allocation order (the most recently created allocation first), regardless
  of funding kind, and fill the destination's active rooms in their original
  order, preserving the order in which units were drawn. Each moved unit
  keeps its provenance: cash keeps its payment identity (and that payment is
  marked as having participated in a transfer) and hotel credit keeps its
  original lot through a new application on the destination group.

  A transfer settles and revalues nothing: it computes no credit bonus,
  resumes no expiry, and records no ledger entry, so no cash, credit, or
  liability total changes.
  """
  def transfer_funding!(%Group{} = source, %Group{} = destination, amount_cents, operation_key) do
    source
    |> draw_units!(amount_cents)
    |> fill_transfer_units!(destination, operation_key)

    :ok
  end

  # Draws `amount_cents` from the source's active-room allocations in
  # reverse allocation order. Each drawn unit keeps its provenance: the
  # payment entry for cash, the original lot for credit.
  defp draw_units!(%Group{} = source, amount_cents) do
    allocations =
      from(a in Allocation,
        join: r in assoc(a, :room),
        where: a.group_id == ^source.id and a.remaining_cents > 0 and r.status == "active",
        order_by: [desc: a.id],
        preload: [:payment_entry, credit_application: :lot]
      )
      |> Repo.all()

    {units, _remaining} =
      Enum.reduce_while(allocations, {[], amount_cents}, fn allocation, {units, remaining} ->
        take = min(allocation.remaining_cents, remaining)

        unit =
          case allocation.kind do
            "cash" ->
              mark_participated_in_transfer!(allocation.payment_entry)
              {"cash", allocation.payment_entry, take}

            "credit" ->
              {"credit", allocation.credit_application.lot, take}
          end

        allocation
        |> Ecto.Changeset.change(remaining_cents: allocation.remaining_cents - take)
        |> Repo.update!()

        if remaining - take == 0 do
          {:halt, {[unit | units], 0}}
        else
          {:cont, {[unit | units], remaining - take}}
        end
      end)

    Enum.reverse(units)
  end

  # Fills the destination's active rooms with the drawn units, in their
  # original room order and preserving the order in which units were drawn.
  defp fill_transfer_units!(units, %Group{} = destination, operation_key) do
    {rooms, gaps} = room_gaps(destination)

    {leftover, _gaps} =
      Enum.reduce(units, {0, gaps}, fn {kind, ref, amount}, {leftover, gaps} ->
        {chunk_leftover, gaps} =
          case kind do
            "cash" ->
              fill_one_chunk!(destination, rooms, gaps, "cash", ref, amount)

            "credit" ->
              application = insert_transfer_application!(destination, ref, amount, operation_key)

              fill_one_chunk!(destination, rooms, gaps, "credit", application, amount)
          end

        {leftover + chunk_leftover, gaps}
      end)

    if leftover != 0 do
      raise ArgumentError, "transferred funding exceeds the destination rooms' deposits"
    end

    :ok
  end

  # A transfer keeps hotel credit applied to a group; the destination's share
  # is recorded as a new application against the original lot.
  defp insert_transfer_application!(
         %Group{} = destination,
         %Lot{} = lot,
         amount_cents,
         operation_key
       ) do
    %Application{}
    |> Application.changeset(%{
      group_id: destination.id,
      lot_id: lot.id,
      amount_cents: amount_cents,
      status: "applied",
      operation_key: operation_key
    })
    |> Repo.insert!()
  end

  # Unattributed funding has no payment identity to mark.
  defp mark_participated_in_transfer!(nil), do: :ok

  defp mark_participated_in_transfer!(%Entry{} = payment_entry) do
    unless payment_entry.participated_in_transfer do
      payment_entry
      |> Ecto.Changeset.change(participated_in_transfer: true)
      |> Repo.update!()
    end

    :ok
  end

  ## Reducing recorded cash

  @doc """
  Records a provider correction against one cash payment: removes held
  allocations belonging to the payment in reverse fill order, reopening the
  active rooms' outstanding deposit by the amount removed.

  Returns the primary keys of every group whose held funding changed; the
  payment's allocations may span groups after a deposit transfer.
  """
  def reduce_payment!(%Entry{} = payment_entry, amount_cents, occurred_on) do
    {_removed, affected_groups} =
      payment_entry.id
      |> held_allocations()
      |> carve_allocations!(amount_cents)

    Ledger.record_reduction!(payment_entry, amount_cents, occurred_on)

    affected_groups
  end

  ## Charging back a payment

  @doc """
  Reverses all cash from one payment except any portion already recorded as
  reduced:

    - held allocations are removed in reverse fill order, reopening the
      active rooms' outstanding deposit;
    - refunded, retained, and converted portions are reclassified as
      charged-back cash without reversing the historical refund or retention;
    - converted principal has its credit entitlement revoked: the entitlement
      is removed from the lot's remaining balance first, and whatever cannot
      be removed becomes the lot's unrecovered clawback.

  Returns the charged-back amount and the primary keys of every group whose
  held funding changed; the payment's allocations may span groups after a
  deposit transfer.
  """
  def charge_back_payment!(%Entry{} = payment_entry, occurred_on) do
    {held_removed, affected_groups} =
      payment_entry.id
      |> held_allocations()
      |> carve_allocations!(:all)

    Ledger.reclassify_payment_dispositions!(payment_entry.id)

    if held_removed > 0 do
      Ledger.record_chargeback!(payment_entry, held_removed, occurred_on)
    end

    revoke_entitlements!(payment_entry.id)

    charged_back =
      payment_entry.amount_cents - Ledger.disposition_cents(payment_entry.id, "cash_reduction")

    {charged_back, affected_groups}
  end

  defp held_allocations(payment_entry_pk) do
    from(a in Allocation,
      where: a.payment_entry_id == ^payment_entry_pk and a.remaining_cents > 0,
      order_by: [desc: a.id],
      preload: [:payment_entry]
    )
    |> Repo.all()
  end

  # Removes `amount` (or everything with :all) from the held allocations in
  # reverse fill order. Returns the amount removed together with the primary
  # keys of the groups whose held funding changed.
  defp carve_allocations!(allocations, :all) do
    removed = Enum.sum_by(allocations, & &1.remaining_cents)
    affected_groups = Enum.uniq(Enum.map(allocations, & &1.group_id))

    for allocation <- allocations do
      allocation
      |> Ecto.Changeset.change(remaining_cents: 0)
      |> Repo.update!()
    end

    {removed, affected_groups}
  end

  defp carve_allocations!(allocations, amount), do: carve_allocations!(allocations, amount, 0, [])

  defp carve_allocations!([], _amount, removed, affected_groups), do: {removed, affected_groups}

  defp carve_allocations!(_allocations, 0, removed, affected_groups),
    do: {removed, affected_groups}

  defp carve_allocations!([allocation | rest], amount, removed, affected_groups) do
    take = min(allocation.remaining_cents, amount)

    allocation
    |> Ecto.Changeset.change(remaining_cents: allocation.remaining_cents - take)
    |> Repo.update!()

    carve_allocations!(rest, amount - take, removed + take, [
      allocation.group_id | affected_groups
    ])
  end

  defp revoke_entitlements!(payment_entry_pk) do
    from(e in Entitlement,
      where: e.payment_entry_id == ^payment_entry_pk,
      preload: [:lot]
    )
    |> Repo.all()
    |> Enum.each(fn entitlement ->
      lot = Repo.get!(Lot, entitlement.lot_id)

      removed = min(entitlement.entitlement_cents, lot.remaining_cents)

      lot
      |> Ecto.Changeset.change(
        remaining_cents: lot.remaining_cents - removed,
        unrecovered_clawback_cents:
          lot.unrecovered_clawback_cents + (entitlement.entitlement_cents - removed)
      )
      |> Repo.update!()
    end)

    :ok
  end
end
