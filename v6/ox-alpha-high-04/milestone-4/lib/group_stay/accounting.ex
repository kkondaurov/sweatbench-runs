defmodule GroupStay.Accounting do
  @moduledoc """
  Room-level deposit accounting.

  Cash and hotel credit fund active rooms' deposits in the rooms' original
  order, filling one room's deposit before moving to the next; funding
  operations allocate in operation-processing order. Every funded piece is
  kept as a `GroupStay.Finance.Disposition` row, whose auto-increment id
  preserves the fill order, so settlements, provider corrections, and
  chargebacks can address exactly the cash that belongs to one payment —
  and the unattributed funding that predates durable operation records can
  never be mistaken for recorded funding.
  """

  import Ecto.Query

  alias GroupStay.Bookings.Group
  alias GroupStay.Bookings.Room
  alias GroupStay.Finance.CreditLot
  alias GroupStay.Finance.Disposition
  alias GroupStay.Finance.LotEntitlement
  alias GroupStay.Repo

  @fund_cash "cash"
  @fund_credit "hotel_credit"

  ## Room and group state

  def active_rooms(group_id) do
    from(r in Room,
      where: r.group_id == ^group_id and r.status == "active",
      order_by: [asc: r.position]
    )
    |> Repo.all()
  end

  @doc """
  The room's remaining deposit capacity: what its active funding has not
  covered yet.
  """
  def room_capacity(room),
    do: room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents

  def outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents

  @doc """
  Rebuilds the group's aggregate totals from its active rooms: lodging,
  deposit due, paid, and outstanding all describe the active rooms only.
  A group whose last active room settles becomes `cancelled`.
  """
  def recompute_group(group) do
    rooms = active_rooms(group.group_id)
    nights = Date.diff(group.departure_on, group.arrival_on)

    cash = Enum.sum(Enum.map(rooms, & &1.cash_paid_cents))
    credit = Enum.sum(Enum.map(rooms, & &1.credit_paid_cents))

    changes = %{
      lodging_total_cents: Enum.sum(Enum.map(rooms, &(&1.nightly_rate_cents * nights))),
      deposit_due_cents: Enum.sum(Enum.map(rooms, & &1.deposit_due_cents)),
      cash_paid_cents: cash,
      credit_paid_cents: credit,
      deposit_paid_cents: cash + credit
    }

    changes =
      if rooms == [], do: Map.put(changes, :status, "cancelled"), else: changes

    Repo.update!(Ecto.Changeset.change(group, changes))
  end

  ## Funding

  @doc """
  Allocates `amount` of one fund across the group's active rooms in their
  original order, filling one room's deposit before moving to the next.

  Returns the updated group and the list of `{room, take}` chunks, in fill
  order. Aggregate cash, credit, and liability balances change only through
  the caller's regular accounting; allocations merely classify them.
  """
  def allocate(group, fund, owner, amount, occurred_on) do
    rooms = active_rooms(group.group_id)
    chunks = fill_rooms(rooms, fund, owner, nil, amount, occurred_on)
    group = recompute_group(group)
    {group, chunks}
  end

  defp fill_rooms(rooms, fund, owner, lot_id, amount, occurred_on) do
    {chunks, _left} =
      Enum.map_reduce(rooms, amount, fn room, left ->
        take = min(room_capacity(room), max(left, 0))

        if take > 0 do
          insert_disposition(%{
            group_id: room.group_id,
            room_id: room.room_id,
            payment_operation_id: owner,
            fund: fund,
            kind: "held",
            lot_id: lot_id,
            amount_cents: take,
            occurred_on: occurred_on
          })

          credit_room(room, fund, take)
          {{room, take}, left - take}
        else
          {nil, left}
        end
      end)

    Enum.reject(chunks, &is_nil/1)
  end

  defp insert_disposition(attrs) do
    %Disposition{}
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert!()
  end

  defp credit_room(room, @fund_cash, take),
    do: Repo.update!(Ecto.Changeset.change(room, cash_paid_cents: room.cash_paid_cents + take))

  defp credit_room(room, _fund, take),
    do:
      Repo.update!(Ecto.Changeset.change(room, credit_paid_cents: room.credit_paid_cents + take))

  ## Hotel-credit application

  @doc """
  Redeems up to `amount_cents` of the group's guest credit into the group's
  active rooms. Lots are consumed by earliest expiry, then by source
  operation; each taken portion is held against its lot so a refundable
  settlement can restore it. Returns `{:ok, group}` with the recomputed
  group, or `{:error, :insufficient_credit}`.
  """
  def apply_group_credit(group, occurred_on, operation_id, amount_cents) do
    guest_id = group.guest_id

    if GroupStay.available_credit(guest_id, occurred_on) < amount_cents do
      {:error, :insufficient_credit}
    else
      rooms = active_rooms(group.group_id)

      {chunks, _left} =
        Enum.map_reduce(GroupStay.available_lots(guest_id, occurred_on), amount_cents, fn lot,
                                                                                          left ->
          take = min(lot.remaining_cents, max(left, 0))

          if take > 0 do
            Repo.update!(Ecto.Changeset.change(lot, remaining_cents: lot.remaining_cents - take))

            room_chunks = fill_rooms(rooms, @fund_credit, operation_id, lot.id, take, occurred_on)
            {room_chunks, left - take}
          else
            {[], left}
          end
        end)

      _room_chunks = Enum.concat(chunks)
      {:ok, recompute_group(group)}
    end
  end

  ## Settlement of selected rooms

  @doc """
  Settles the held cash and credit of the selected rooms using the
  cancellation's rules: refundable cash refunds or converts to hotel credit
  (one lot for the combined cash, with telescoping entitlements), otherwise
  cash is retained. Applied credit returns to its lots on a refundable
  settlement — extinguishing any unrecovered clawback first — and is
  consumed by a non-refundable one. Unpaid deposit for the rooms ceases to
  be due.

  Returns `{group, settled_cash_cents, credit_issued_cents}`.
  """
  def settle_rooms(group, rooms, mode, occurred_on, operation_id, refundable?) do
    room_ids = Enum.map(rooms, & &1.room_id)
    held = held_dispositions(group.group_id, room_ids)
    cash_rows = Enum.filter(held, &(&1.fund == @fund_cash))
    credit_rows = Enum.filter(held, &(&1.fund == @fund_credit))

    cash_total = Enum.sum(Enum.map(cash_rows, & &1.amount_cents))
    issued = settle_cash(group, cash_rows, cash_total, mode, occurred_on, operation_id)
    settle_credit(group, credit_rows, refundable?, occurred_on)

    for room <- rooms do
      Repo.update!(
        Ecto.Changeset.change(room, %{
          status: "cancelled",
          cash_paid_cents: 0,
          credit_paid_cents: 0
        })
      )
    end

    group = recompute_group(group)
    {group, cash_total, issued}
  end

  defp settle_cash(_group, _rows, 0, _mode, _occurred_on, _operation_id), do: 0

  defp settle_cash(group, rows, cash_total, :convert, occurred_on, operation_id) do
    lot = GroupStay.issue_hotel_credit_lot(group.guest_id, operation_id, cash_total, occurred_on)
    create_entitlements(lot.id, rows)
    reclassify(rows, "converted", lot.id, occurred_on)

    GroupStay.record_ledger_entry(%{
      kind: "converted_to_credit",
      amount: cash_total,
      group_id: group.group_id,
      occurred_on: occurred_on
    })

    lot_amount(cash_total)
  end

  defp settle_cash(group, rows, cash_total, mode, occurred_on, _operation_id) do
    kind = if mode == :refund, do: "refunded", else: "retained"
    reclassify(rows, kind, nil, occurred_on)

    GroupStay.record_ledger_entry(%{
      kind: kind,
      amount: cash_total,
      group_id: group.group_id,
      occurred_on: occurred_on
    })

    0
  end

  defp lot_amount(cash_total), do: GroupStay.hotel_credit_lot_amount(cash_total)

  # Entitlements telescope exactly to the issued lot: per payment, the
  # issued value of the cash converted through that payment minus the issued
  # value through the preceding payment, in fill order. The unattributed
  # senior block advances the running total without claiming.
  defp create_entitlements(lot_id, rows) do
    {claims, _running} =
      Enum.map_reduce(rows, 0, fn row, running ->
        through = running + row.amount_cents

        claim =
          if row.payment_operation_id,
            do:
              GroupStay.hotel_credit_lot_amount(through) -
                GroupStay.hotel_credit_lot_amount(running),
            else: 0

        {{row.payment_operation_id, claim}, through}
      end)

    claims
    |> Enum.group_by(fn {owner, _claim} -> owner end, fn {_owner, claim} -> claim end)
    |> Enum.each(fn
      {nil, _claims} ->
        # The unattributed senior block advances the running total without
        # claiming a bonus of its own.
        :skip

      {owner, claims} ->
        entitled = Enum.sum(claims)

        if entitled > 0 do
          %LotEntitlement{}
          |> Ecto.Changeset.change(%{
            lot_id: lot_id,
            payment_operation_id: owner,
            entitled_cents: entitled,
            removed_cents: 0
          })
          |> Repo.insert!()
        end
    end)
  end

  defp reclassify(rows, kind, lot_id, occurred_on) do
    for row <- rows do
      changes = %{kind: kind, occurred_on: occurred_on}
      changes = if lot_id, do: Map.put(changes, :lot_id, lot_id), else: changes
      Repo.update!(Ecto.Changeset.change(row, changes))
    end

    :ok
  end

  defp settle_credit(_group, [], _refundable?, _restore_on), do: :ok

  defp settle_credit(_group, credit_rows, refundable?, restore_on) do
    if refundable? do
      credit_rows
      |> Enum.group_by(& &1.lot_id, & &1.amount_cents)
      |> Enum.map(fn {lot_id, amounts} -> {lot_id, Enum.sum(amounts)} end)
      |> Enum.each(fn {lot_id, amount} -> restore_to_lot(lot_id, amount, restore_on) end)
    else
      # Applied credit is consumed by a non-refundable settlement: it leaves
      # the liability permanently and nothing returns to any lot.
      :ok
    end

    Repo.delete_all(from(d in Disposition, where: d.id in ^Enum.map(credit_rows, & &1.id)))
    :ok
  end

  # Restores an applied amount to its lot. An unrecovered clawback absorbs
  # the return first — before the lot's expiry is even checked — and only an
  # excess becomes available, and only while the lot is still unexpired.
  defp restore_to_lot(lot_id, amount, restore_on) do
    lot = Repo.get!(CreditLot, lot_id)
    absorbed = min(lot.unrecovered_clawback_cents, amount)

    changes = %{unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed}

    returns = amount - absorbed

    changes =
      if Date.compare(lot.expires_on, restore_on) != :lt,
        do: Map.put(changes, :remaining_cents, lot.remaining_cents + returns),
        else: changes

    Repo.update!(Ecto.Changeset.change(lot, changes))
  end

  ## Provider corrections

  @doc "Cash from the recorded payment still held on active rooms."
  def held_total(payment_operation_id) do
    from(d in Disposition,
      where:
        d.payment_operation_id == ^payment_operation_id and d.fund == @fund_cash and
          d.kind == "held",
      select: coalesce(sum(d.amount_cents), 0)
    )
    |> Repo.one()
  end

  def reduced_total(payment_operation_id) do
    classification_total(payment_operation_id, "reduced")
  end

  def charged_back_total(payment_operation_id) do
    classification_total(payment_operation_id, "charged_back")
  end

  defp classification_total(payment_operation_id, kind) do
    from(d in Disposition,
      where:
        d.payment_operation_id == ^payment_operation_id and d.fund == @fund_cash and
          d.kind == ^kind,
      select: coalesce(sum(d.amount_cents), 0)
    )
    |> Repo.one()
  end

  @doc """
  Removes held cash belonging to the target payment in reverse fill order,
  reopening the active rooms' outstanding deposit. Returns the updated group.
  """
  def reduce_held(payment_operation_id, amount, occurred_on) do
    rows =
      from(d in Disposition,
        where:
          d.payment_operation_id == ^payment_operation_id and d.fund == @fund_cash and
            d.kind == "held",
        order_by: [desc: d.id]
      )
      |> Repo.all()

    {removed, _left} =
      Enum.map_reduce(rows, amount, fn row, left ->
        take = min(row.amount_cents, max(left, 0))

        if take > 0 do
          Repo.update!(
            Ecto.Changeset.change(row, %{
              kind: "reduced",
              amount_cents: take,
              occurred_on: occurred_on
            })
          )

          # The removed amount becomes recorded as reduced; a partially
          # reduced row keeps its remainder held in place, re-entering the
          # fill order behind everything allocated before it.
          if take < row.amount_cents do
            insert_disposition(%{
              group_id: row.group_id,
              room_id: row.room_id,
              payment_operation_id: row.payment_operation_id,
              fund: row.fund,
              kind: "held",
              lot_id: row.lot_id,
              amount_cents: row.amount_cents - take,
              occurred_on: occurred_on
            })
          end

          debit_room(row.group_id, row.room_id, take)
          {{row, take}, left - take}
        else
          {nil, left}
        end
      end)

    total =
      removed |> Enum.reject(&is_nil/1) |> Enum.map(fn {_row, take} -> take end) |> Enum.sum()

    group_id = group_of_owner(payment_operation_id)

    GroupStay.record_ledger_entry(%{
      kind: "reduced",
      amount: total,
      group_id: group_id,
      occurred_on: occurred_on
    })

    recompute_group(Repo.get!(Group, group_id))
  end

  # Reduces only ever move cash off the room.
  defp debit_room(_group_id, nil, _take), do: :ok

  defp debit_room(group_id, room_id, take) do
    room = Repo.get_by!(Room, group_id: group_id, room_id: room_id)

    Repo.update!(Ecto.Changeset.change(room, cash_paid_cents: room.cash_paid_cents - take))
  end

  defp group_of_owner(payment_operation_id) do
    from(d in Disposition,
      where: d.payment_operation_id == ^payment_operation_id,
      select: d.group_id,
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Reverses all cash from one recorded payment except any portion already
  recorded as reduced: held allocations are removed in reverse fill order
  (reopening the active rooms' outstanding deposit), refunded and retained
  portions move to charged-back cash, and converted principal moves to
  charged-back cash while its credit entitlement is revoked. The historical
  refund or retention itself is not reversed or reissued.

  Returns `{group, charged_back_cents}`.
  """
  def charge_back(payment_operation_id, occurred_on) do
    rows =
      from(d in Disposition,
        where:
          d.payment_operation_id == ^payment_operation_id and d.fund == @fund_cash and
            d.kind in ["held", "refunded", "retained", "converted"]
      )
      |> Repo.all()

    total = Enum.sum(Enum.map(rows, & &1.amount_cents))
    group_id = group_of_owner(payment_operation_id)

    for row <- rows do
      if row.kind == "held" do
        debit_room(row.group_id, row.room_id, row.amount_cents)
      end

      if row.kind == "converted" do
        claw_back(row.lot_id, payment_operation_id)
      end

      Repo.update!(Ecto.Changeset.change(row, %{kind: "charged_back", occurred_on: occurred_on}))
    end

    GroupStay.record_ledger_entry(%{
      kind: "charged_back",
      amount: total,
      group_id: group_id,
      occurred_on: occurred_on
    })

    group = recompute_group(Repo.get!(Group, group_id))
    {group, total}
  end

  # Takes the payment's entitlement out of the lot's remaining balance
  # first; whatever cannot be removed becomes the lot's unrecovered clawback.
  defp claw_back(nil, _payment_operation_id), do: :ok

  defp claw_back(lot_id, payment_operation_id) do
    entitlement =
      Repo.one(
        from(e in LotEntitlement,
          where: e.lot_id == ^lot_id and e.payment_operation_id == ^payment_operation_id
        )
      )

    case entitlement do
      nil ->
        :ok

      %{removed_cents: removed, entitled_cents: entitled} = entitlement ->
        claim = entitled - removed

        if claim > 0 do
          lot = Repo.get!(CreditLot, lot_id)
          removed_now = min(claim, lot.remaining_cents)

          Repo.update!(
            Ecto.Changeset.change(lot, %{
              remaining_cents: lot.remaining_cents - removed_now,
              unrecovered_clawback_cents: lot.unrecovered_clawback_cents + claim - removed_now
            })
          )

          Repo.update!(Ecto.Changeset.change(entitlement, removed_cents: entitled))
        end
    end
  end

  ## Reads

  defp held_dispositions(group_id, room_ids) do
    from(d in Disposition,
      where: d.group_id == ^group_id and d.kind == "held" and d.room_id in ^room_ids,
      order_by: [asc: d.id]
    )
    |> Repo.all()
  end

  @doc """
  The current disposition of one recorded payment's cash. The six
  classification amounts always sum exactly to the recorded amount.
  """
  def payment_statement(payment_operation_id) do
    rows =
      from(d in Disposition,
        where: d.payment_operation_id == ^payment_operation_id and d.fund == @fund_cash,
        select: {d.kind, d.amount_cents}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {kind, amounts} -> {kind, Enum.sum(amounts)} end)

    %{
      held_cents: Map.get(rows, "held", 0),
      refunded_cents: Map.get(rows, "refunded", 0),
      retained_cents: Map.get(rows, "retained", 0),
      converted_to_credit_cents: Map.get(rows, "converted", 0),
      reduced_cents: Map.get(rows, "reduced", 0),
      charged_back_cents: Map.get(rows, "charged_back", 0)
    }
  end
end
