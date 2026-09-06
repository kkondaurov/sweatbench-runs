defmodule GroupStay.Funding do
  @moduledoc """
  Room-level funding accounting.

  Cash and credit fund a group's active rooms in the rooms' original order,
  filling one room's deposit before moving to the next. New funding operations
  allocate in operation-processing order. Every funded amount is recorded as a
  `GroupStay.Funding.Allocation` row so that individual payments can be reduced
  or charged back and individual rooms can be settled.

  This module owns the allocation primitives: filling rooms with new funding,
  reading per-room funding totals, reclassifying funded amounts in fill or
  reverse-fill order, and the one-time backfill that brings pre-release funding
  forward as room allocations.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.Credit.Application
  alias GroupStay.Funding.Allocation
  alias GroupStay.Groups.Group
  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  @flexible_deposit_percent 20

  ## Deposit calculation

  @doc """
  Returns the deposit required for one room given its rate plan and lodging.
  Flexible rooms require a 20% deposit; advance-purchase rooms require their
  full lodging amount.
  """
  def room_deposit("advance_purchase", lodging_cents), do: lodging_cents

  def room_deposit("flexible", lodging_cents) do
    round_half_up(lodging_cents * @flexible_deposit_percent, 100)
  end

  @doc """
  Rounds `numerator / denominator` to the nearest integer, with an exact half
  rounding upward.
  """
  def round_half_up(numerator, denominator) do
    div(numerator + div(denominator, 2), denominator)
  end

  ## Reads

  @doc """
  Returns the held allocations for a group, in fill order.
  """
  def held_for(group_id) do
    Repo.all(
      from a in Allocation,
        where: a.group_id == ^group_id and a.disposition == "held",
        order_by: [asc: a.fill_sequence, asc: a.id]
    )
  end

  @doc """
  Returns the held cash allocations recorded for one payment, in fill order.
  """
  def held_for_payment(payment_operation_id) do
    Repo.all(
      from a in Allocation,
        where:
          a.kind == "cash" and a.disposition == "held" and
            a.payment_operation_id == ^payment_operation_id,
        order_by: [asc: a.fill_sequence, asc: a.id]
    )
  end

  @doc """
  Returns every cash allocation recorded for one payment, in fill order.
  """
  def all_for_payment(payment_operation_id) do
    Repo.all(
      from a in Allocation,
        where: a.kind == "cash" and a.payment_operation_id == ^payment_operation_id,
        order_by: [asc: a.fill_sequence, asc: a.id]
    )
  end

  @doc """
  Reduces held allocations to a map of per-room funding totals:
  `%{room_id => %{cash: cents, credit: cents}}`.
  """
  def room_paid_map(held_allocations) do
    Enum.reduce(held_allocations, %{}, fn a, acc ->
      %{cash: cash, credit: credit} = Map.get(acc, a.room_id, %{cash: 0, credit: 0})

      entry =
        case a.kind do
          "cash" -> %{cash: cash + a.amount_cents, credit: credit}
          "credit" -> %{cash: cash, credit: credit + a.amount_cents}
        end

      Map.put(acc, a.room_id, entry)
    end)
  end

  @doc """
  Returns the group's active rooms in their original order.
  """
  def active_rooms(rooms) do
    Enum.filter(rooms, fn room -> Map.get(room, :status, "active") == "active" end)
  end

  defp next_sequence(group_id) do
    max =
      Repo.one(
        from a in Allocation,
          where: a.group_id == ^group_id,
          select: max(a.fill_sequence)
      )

    (max || 0) + 1
  end

  ## Live allocation

  @doc """
  Allocates `amount_cents` of cash from one payment across the group's active
  rooms in their original order. Returns the inserted allocation rows.
  """
  def allocate_cash(group, amount_cents, payment_operation_id) do
    paid = room_paid_map(held_for(group.id))
    seq = next_sequence(group.id)

    rooms =
      group.rooms
      |> active_rooms()
      |> Enum.map(fn room -> {room, room_remaining(room, paid)} end)

    {rows, _seq} = fill_cash(rooms, amount_cents, seq, group.id, payment_operation_id, "held")
    Enum.each(rows, &Repo.insert!/1)
    rows
  end

  @doc """
  Allocates credit across the group's active rooms in their original order.
  `lot_portions` is a list of `{lot_id, amount_cents}` in consumption order;
  each room is funded from the portions in order so the lot source of every
  funded amount is preserved for later restoration. Returns the inserted rows.
  """
  def allocate_credit(group, lot_portions) do
    paid = room_paid_map(held_for(group.id))
    seq = next_sequence(group.id)

    rooms =
      group.rooms
      |> active_rooms()
      |> Enum.map(fn room -> {room, room_remaining(room, paid)} end)

    {rows, _seq} = fill_credit(rooms, lot_portions, group.id, seq, "held")
    Enum.each(rows, &Repo.insert!/1)
    rows
  end

  ## Reclassification

  @doc """
  Reclassifies up to `amount_cents` from the ordered allocations to
  `disposition`, consuming them in the given order. A partially consumed
  allocation is split so the remainder keeps its original disposition.
  """
  def reclassify_in_order(allocations, amount_cents, disposition) do
    Enum.reduce_while(allocations, amount_cents, fn allocation, remaining ->
      if remaining == 0 do
        {:halt, 0}
      else
        take = min(allocation.amount_cents, remaining)
        reclassify_portion(allocation, take, disposition)
        {:cont, remaining - take}
      end
    end)
  end

  @doc """
  Reclassifies every allocation in the list to `disposition`.
  """
  def reclassify_all(allocations, disposition) do
    Enum.each(allocations, fn allocation ->
      allocation
      |> Changeset.change(disposition: disposition)
      |> Repo.update!()
    end)
  end

  defp reclassify_portion(allocation, take, disposition) do
    if take == allocation.amount_cents do
      allocation
      |> Changeset.change(disposition: disposition)
      |> Repo.update!()
    else
      allocation
      |> Changeset.change(amount_cents: allocation.amount_cents - take)
      |> Repo.update!()

      Repo.insert!(%Allocation{
        group_id: allocation.group_id,
        room_id: allocation.room_id,
        kind: allocation.kind,
        payment_operation_id: allocation.payment_operation_id,
        credit_lot_id: allocation.credit_lot_id,
        amount_cents: take,
        disposition: disposition,
        fill_sequence: allocation.fill_sequence
      })
    end
  end

  defp room_remaining(room, paid_map) do
    %{cash: cash, credit: credit} = Map.get(paid_map, room.room_id, %{cash: 0, credit: 0})
    room_deposit_due(room) - cash - credit
  end

  defp room_deposit_due(room) do
    case Map.get(room, :deposit_due_cents) do
      nil -> 0
      cents -> cents
    end
  end

  ## Fill helpers

  defp fill_cash(rooms, amount, seq, group_id, payment_operation_id, disposition) do
    do_fill_cash(rooms, amount, seq, group_id, payment_operation_id, disposition, [])
  end

  defp do_fill_cash(_rooms, 0, seq, _group_id, _payment_operation_id, _disposition, rows),
    do: {Enum.reverse(rows), seq}

  defp do_fill_cash([], _amount, seq, _group_id, _payment_operation_id, _disposition, rows),
    do: {Enum.reverse(rows), seq}

  defp do_fill_cash([{_room, 0} | rest], amount, seq, group_id, payment_operation_id, d, rows) do
    do_fill_cash(rest, amount, seq, group_id, payment_operation_id, d, rows)
  end

  defp do_fill_cash([{room, cap} | rest], amount, seq, group_id, payment_operation_id, d, rows) do
    take = min(cap, amount)

    row = %Allocation{
      group_id: group_id,
      room_id: room.room_id,
      kind: "cash",
      payment_operation_id: payment_operation_id,
      amount_cents: take,
      disposition: d,
      fill_sequence: seq
    }

    do_fill_cash(rest, amount - take, seq + 1, group_id, payment_operation_id, d, [row | rows])
  end

  defp fill_credit(rooms, lot_portions, group_id, seq, disposition) do
    do_fill_credit(rooms, lot_portions, group_id, seq, disposition, [])
  end

  defp do_fill_credit(_rooms, [], _group_id, seq, _disposition, rows),
    do: {Enum.reverse(rows), seq}

  defp do_fill_credit([], _portions, _group_id, seq, _disposition, rows),
    do: {Enum.reverse(rows), seq}

  defp do_fill_credit([{_room, 0} | rest], portions, group_id, seq, disposition, rows) do
    do_fill_credit(rest, portions, group_id, seq, disposition, rows)
  end

  defp do_fill_credit(
         [{room, cap} | rest],
         [{lot_id, lot_remaining} | portions],
         gid,
         seq,
         d,
         rows
       ) do
    take = min(cap, lot_remaining)

    row = %Allocation{
      group_id: gid,
      room_id: room.room_id,
      kind: "credit",
      credit_lot_id: lot_id,
      amount_cents: take,
      disposition: d,
      fill_sequence: seq
    }

    cond do
      take == cap and lot_remaining - take > 0 ->
        do_fill_credit(rest, [{lot_id, lot_remaining - take} | portions], gid, seq + 1, d, [
          row | rows
        ])

      take == cap ->
        do_fill_credit(rest, portions, gid, seq + 1, d, [row | rows])

      true ->
        do_fill_credit([{room, cap - take} | rest], portions, gid, seq + 1, d, [row | rows])
    end
  end

  ## Backfill

  @doc """
  Brings pre-release funding forward as room allocations.

  A database created by an earlier release can contain groups funded before
  durable operation records existed. That funding is carried forward as one
  unattributed senior block per group (aggregate cash first, then hotel-credit
  lots in original consumption order) and allocated before funding represented
  by durable operation records, which is classified by the retained operation
  type and allocated in durable-record commit order regardless of
  `occurred_on`. Creating room allocations does not change any aggregate cash,
  credit, or liability balance.

  Called by the release migration; safe to call again (it skips groups that
  already have allocations).
  """
  def backfill_room_accounting do
    Repo.all(Group)
    |> Enum.each(&backfill_group/1)

    :ok
  end

  defp backfill_group(group) do
    unless Repo.exists?(from a in Allocation, where: a.group_id == ^group.id) do
      group = backfill_group_rooms(group)
      plan = build_funding_plan(group)
      create_backfill_allocations(group, plan)
      finalize_backfill_columns(group)
    end
  end

  defp backfill_group_rooms(group) do
    nights = Date.diff(group.departure_on, group.arrival_on)
    status = if group.status == "active", do: "active", else: "cancelled"

    rooms =
      Enum.map(group.rooms, fn room ->
        lodging = nights * room.nightly_rate_cents

        %{
          room
          | status: status,
            lodging_cents: lodging,
            deposit_due_cents: room_deposit(group.rate_plan, lodging)
        }
      end)

    group
    |> Changeset.change(rooms: rooms)
    |> Repo.update!()
  end

  # Builds the ordered funding plan for a group: the unattributed senior block
  # first, then durable funding operations in commit order. Each plan entry is
  # either `{:cash, amount, payment_operation_id_or_nil, disposition}` or
  # `{:credit, [{lot_id, amount}], disposition}`.
  defp build_funding_plan(group) do
    durable_ops = durable_funding_ops(group)

    case group.status do
      "active" -> active_plan(group, durable_ops)
      _other -> cancelled_plan(group, durable_ops)
    end
  end

  defp active_plan(group, durable_ops) do
    held_cash = group.deposit_paid_cents - group.credit_paid_cents
    held_credit = group.credit_paid_cents
    legacy_cash = max(held_cash - durable_cash_total(durable_ops), 0)
    legacy_credit = max(held_credit - durable_credit_total(durable_ops), 0)

    all_lots = applied_lot_portions(group.id)
    {legacy_credit_portions, rest_lots} = split_portions(all_lots, legacy_credit)

    legacy_entries =
      cash_entry(legacy_cash, nil, "held") ++ credit_entry(legacy_credit_portions, "held")

    {durable_entries, _lots} =
      Enum.map_reduce(durable_ops, rest_lots, fn op, lots ->
        case op.kind do
          :cash ->
            {{:cash, op.amount, op.operation_id, "held"}, lots}

          :credit ->
            {portions, rest} = split_portions(lots, op.amount)
            {{:credit, portions, "held"}, rest}
        end
      end)

    legacy_entries ++ durable_entries
  end

  defp cancelled_plan(group, durable_ops) do
    disposition =
      cond do
        group.refunded_cents > 0 -> "refunded"
        group.retained_cents > 0 -> "retained"
        group.converted_cents > 0 -> "converted"
        true -> nil
      end

    if disposition == nil do
      []
    else
      total_cash = group.refunded_cents + group.retained_cents + group.converted_cents
      legacy_cash = max(total_cash - durable_cash_total(durable_ops), 0)

      legacy_entries = cash_entry(legacy_cash, nil, disposition)

      durable_entries =
        for op <- durable_ops,
            op.kind == :cash,
            do: {:cash, op.amount, op.operation_id, disposition}

      legacy_entries ++ durable_entries
    end
  end

  defp cash_entry(0, _payment_operation_id, _disposition), do: []

  defp cash_entry(amount, payment_operation_id, disposition),
    do: [{:cash, amount, payment_operation_id, disposition}]

  defp credit_entry([], _disposition), do: []
  defp credit_entry(portions, disposition), do: [{:credit, portions, disposition}]

  defp durable_cash_total(durable_ops) do
    durable_ops
    |> Enum.filter(&(&1.kind == :cash))
    |> Enum.reduce(0, &(&1.amount + &2))
  end

  defp durable_credit_total(durable_ops) do
    durable_ops
    |> Enum.filter(&(&1.kind == :credit))
    |> Enum.reduce(0, &(&1.amount + &2))
  end

  # Returns applied funding operations addressed to the group in durable-record
  # commit order, regardless of `occurred_on`.
  defp durable_funding_ops(group) do
    Repo.all(from r in Record, order_by: [asc: r.id])
    |> Enum.flat_map(fn record ->
      if record.type in ["record_cash_payment", "apply_hotel_credit"] do
        case Jason.decode(record.result) do
          {:ok, result} ->
            if result["status"] == "applied" and result["group_id"] == group.group_id do
              kind = if record.type == "record_cash_payment", do: :cash, else: :credit

              [
                %{
                  kind: kind,
                  operation_id: record.operation_id,
                  amount: result["amount_cents"] || 0
                }
              ]
            else
              []
            end

          _other ->
            []
        end
      else
        []
      end
    end)
  end

  # Returns the lots currently applied to the group with their amounts, in
  # original consumption order.
  defp applied_lot_portions(group_id) do
    Repo.all(
      from a in Application,
        where: a.group_id == ^group_id,
        order_by: [asc: a.inserted_at, asc: a.id]
    )
    |> Enum.map(fn application -> {application.credit_lot_id, application.amount_cents} end)
  end

  # Splits lot portions into the first `amount` cents and the remainder.
  defp split_portions(portions, amount) do
    do_split_portions(portions, amount, [])
  end

  defp do_split_portions(portions, 0, taken), do: {Enum.reverse(taken), portions}
  defp do_split_portions([], _amount, taken), do: {Enum.reverse(taken), []}

  defp do_split_portions([{lot_id, portion} | rest], amount, taken) do
    take = min(portion, amount)
    remaining_portion = portion - take
    remaining = if remaining_portion > 0, do: [{lot_id, remaining_portion} | rest], else: rest
    do_split_portions(remaining, amount - take, [{lot_id, take} | taken])
  end

  # Fills rooms from scratch with the funding plan, assigning fill sequences in
  # plan order. Rooms are filled in their original order by deposit capacity.
  defp create_backfill_allocations(group, plan) do
    caps =
      Enum.map(group.rooms, fn room ->
        {room.room_id, Map.get(room, :deposit_due_cents) || 0}
      end)

    {_caps, _seq, rows} =
      Enum.reduce(plan, {caps, 1, []}, fn source, {caps, seq, rows} ->
        {caps, seq, new_rows} = backfill_source(group, source, caps, seq)
        {caps, seq, rows ++ new_rows}
      end)

    Enum.each(rows, &Repo.insert!/1)
  end

  defp backfill_source(group, {:cash, amount, payment_operation_id, disposition}, caps, seq) do
    {caps, rows, seq} =
      backfill_fill_cash(caps, amount, group.id, payment_operation_id, disposition, seq, [])

    {caps, seq, rows}
  end

  defp backfill_source(group, {:credit, portions, disposition}, caps, seq) do
    {caps, rows, seq} = backfill_fill_credit(caps, portions, group.id, disposition, seq, [])
    {caps, seq, rows}
  end

  defp backfill_fill_cash(caps, 0, _gid, _payment_operation_id, _d, seq, rows),
    do: {caps, Enum.reverse(rows), seq}

  defp backfill_fill_cash([], _amount, _gid, _payment_operation_id, _d, seq, rows),
    do: {[], Enum.reverse(rows), seq}

  defp backfill_fill_cash([{_room_id, 0} | rest], amount, gid, pid, d, seq, rows) do
    backfill_fill_cash(rest, amount, gid, pid, d, seq, rows)
  end

  defp backfill_fill_cash([{room_id, cap} | rest], amount, gid, pid, d, seq, rows) do
    take = min(cap, amount)

    row = %Allocation{
      group_id: gid,
      room_id: room_id,
      kind: "cash",
      payment_operation_id: pid,
      amount_cents: take,
      disposition: d,
      fill_sequence: seq
    }

    backfill_fill_cash([{room_id, cap - take} | rest], amount - take, gid, pid, d, seq + 1, [
      row | rows
    ])
  end

  defp backfill_fill_credit(caps, [], _gid, _d, seq, rows), do: {caps, Enum.reverse(rows), seq}
  defp backfill_fill_credit([], _portions, _gid, _d, seq, rows), do: {[], Enum.reverse(rows), seq}

  defp backfill_fill_credit([{_room_id, 0} | rest], portions, gid, d, seq, rows) do
    backfill_fill_credit(rest, portions, gid, d, seq, rows)
  end

  defp backfill_fill_credit(
         [{room_id, cap} | rest],
         [{lot_id, lot_remaining} | portions],
         gid,
         d,
         seq,
         rows
       ) do
    take = min(cap, lot_remaining)

    row = %Allocation{
      group_id: gid,
      room_id: room_id,
      kind: "credit",
      credit_lot_id: lot_id,
      amount_cents: take,
      disposition: d,
      fill_sequence: seq
    }

    cond do
      take == cap and lot_remaining - take > 0 ->
        backfill_fill_credit(rest, [{lot_id, lot_remaining - take} | portions], gid, d, seq + 1, [
          row | rows
        ])

      take == cap ->
        backfill_fill_credit(rest, portions, gid, d, seq + 1, [row | rows])

      true ->
        backfill_fill_credit([{room_id, cap - take} | rest], portions, gid, d, seq + 1, [
          row | rows
        ])
    end
  end

  # After creating allocations, align the group's aggregate columns with the
  # active-rooms-only totals the new release reports. Fully cancelled groups
  # have no active rooms; fully active groups keep their existing totals.
  defp finalize_backfill_columns(group) do
    case group.status do
      "active" ->
        :ok

      _other ->
        group
        |> Changeset.change(
          lodging_total_cents: 0,
          deposit_due_cents: 0,
          deposit_paid_cents: 0,
          credit_paid_cents: 0
        )
        |> Repo.update!()
    end
  end
end
