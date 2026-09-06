defmodule GroupStay.Accounting do
  @moduledoc """
  Room-level accounting for group deposits.

  Cash and credit fund active room deposits in the rooms' original order,
  filling one room's deposit before moving to the next. Funding that predates
  durable operation records is brought forward as one unattributed senior
  block per group; durable funding is allocated afterwards in operation
  record commit order.
  """

  import Ecto.Query

  alias GroupStay.Accounting.LegacyFundingMove
  alias GroupStay.Accounting.PaymentDisposition
  alias GroupStay.Accounting.RoomAllocation
  alias GroupStay.Accounting.TransferParticipation
  alias GroupStay.Credit
  alias GroupStay.Credit.CreditAllocation
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Operations.Operation
  alias GroupStay.Repo

  @cash_kind "cash"
  @credit_kind "credit"

  # ------------------------------------------------------------------
  # Rounding and per-room amounts
  # ------------------------------------------------------------------

  @doc "Rounds numerator / denominator to the nearest cent, half up."
  def round_cents_half_up(numerator, denominator)
      when is_integer(numerator) and is_integer(denominator) do
    div(numerator * 2 + denominator, denominator * 2)
  end

  @doc "The 110% hotel-credit value of a cash amount, with the standard rounding."
  def bonus_value(principal), do: principal + round_cents_half_up(principal, 10)

  @doc "The lodging amount of one room for the stay length."
  def room_lodging(nights, nightly_rate_cents), do: nights * nightly_rate_cents

  @doc "The deposit requirement of one room."
  def room_deposit(nights, nightly_rate_cents, "flexible") do
    round_cents_half_up(nights * nightly_rate_cents * 2, 10)
  end

  def room_deposit(nights, nightly_rate_cents, "advance_purchase") do
    nights * nightly_rate_cents
  end

  # ------------------------------------------------------------------
  # Derived group amounts (always computed, never stored)
  # ------------------------------------------------------------------

  def group_lodging(group) do
    Repo.aggregate(
      from(r in Room, where: r.group_id == ^group.id and r.status == "active"),
      :sum,
      :lodging_cents
    ) || 0
  end

  def group_due(group) do
    Repo.aggregate(
      from(r in Room, where: r.group_id == ^group.id and r.status == "active"),
      :sum,
      :deposit_due_cents
    ) || 0
  end

  def cash_held(group), do: allocation_kind_total(group.id, @cash_kind)

  def credit_held(group), do: allocation_kind_total(group.id, @credit_kind)

  @doc "Held allocation total across the whole ledger."
  def allocation_kind_total(kind) do
    Repo.aggregate(
      from(a in RoomAllocation, where: a.kind == ^kind),
      :sum,
      :amount_cents
    ) || 0
  end

  defp allocation_kind_total(group_id, kind) do
    Repo.aggregate(
      from(a in RoomAllocation, where: a.group_id == ^group_id and a.kind == ^kind),
      :sum,
      :amount_cents
    ) || 0
  end

  def cash_held_for_source(source_operation_id) do
    Repo.aggregate(
      from(a in RoomAllocation,
        where: a.kind == @cash_kind and a.source_operation_id == ^source_operation_id
      ),
      :sum,
      :amount_cents
    ) || 0
  end

  def outstanding(%{status: "cancelled"}), do: 0

  def outstanding(group) do
    max(group_due(group) - cash_held(group) - credit_held(group), 0)
  end

  @doc "Current funded amounts per room: %{room.id => %{\"cash\" => c, \"credit\" => x}}."
  def funding_by_room(group) do
    Repo.all(from a in RoomAllocation, where: a.group_id == ^group.id)
    |> Enum.reduce(%{}, fn row, acc ->
      kinds = Map.get(acc, row.room_id, %{})
      kinds = Map.update(kinds, row.kind, row.amount_cents, &(&1 + row.amount_cents))
      Map.put(acc, row.room_id, kinds)
    end)
  end

  def room_json(room, funded) do
    kinds = Map.get(funded, room.id, %{})

    %{
      "room_id" => room.room_id,
      "nightly_rate_cents" => room.nightly_rate_cents,
      "status" => room.status,
      "deposit_due_cents" => room.deposit_due_cents,
      "cash_paid_cents" => Map.get(kinds, @cash_kind, 0),
      "credit_paid_cents" => Map.get(kinds, @credit_kind, 0)
    }
  end

  # ------------------------------------------------------------------
  # Allocation
  # ------------------------------------------------------------------

  @doc """
  Allocates funding events against the active room deposits of a group.

  Each event is a map with `:kind` (\"cash\" or \"credit\"),
  `:amount_cents`, `:source_operation_id` (nil for legacy funding) and
  `:lot_id` (nil for cash). Rooms are filled in original order and each
  event continues where the previous one stopped.
  """
  def allocate!(group, events) when is_list(events) do
    if events == [] do
      :ok
    else
      funded =
        funding_by_room(group)
        |> Map.new(fn {room_id, kinds} ->
          {room_id, Map.get(kinds, @cash_kind, 0) + Map.get(kinds, @credit_kind, 0)}
        end)

      rooms =
        Repo.all(
          from r in Room,
            where: r.group_id == ^group.id and r.status == "active",
            order_by: r.position
        )

      {rows, _funded} =
        Enum.reduce(events, {[], funded}, fn event, {rows, funded} ->
          {new_rows, funded} = fill(rooms, funded, event, group.id)
          {rows ++ new_rows, funded}
        end)

      if rows != [], do: Repo.insert_all(RoomAllocation, rows)
      :ok
    end
  end

  defp fill(rooms, funded, event, group_id) do
    {reversed, _left, funded} =
      Enum.reduce_while(rooms, {[], event.amount_cents, funded}, fn room, {acc, left, funded} ->
        cond do
          left <= 0 ->
            {:halt, {acc, left, funded}}

          true ->
            used = Map.get(funded, room.id, 0)
            capacity = max(room.deposit_due_cents - used, 0)
            take = min(left, capacity)

            if take > 0 do
              row = %{
                group_id: group_id,
                room_id: room.id,
                kind: event.kind,
                source_operation_id: event.source_operation_id,
                lot_id: event.lot_id,
                amount_cents: take,
                inserted_at: now(),
                updated_at: now()
              }

              {:cont, {[row | acc], left - take, Map.put(funded, room.id, used + take)}}
            else
              {:cont, {acc, left, funded}}
            end
        end
      end)

    {Enum.reverse(reversed), funded}
  end

  @doc """
  Materializes any funding without allocation rows yet: the legacy
  unattributed senior block (aggregate cash first, then hotel-credit lots in
  original consumption order) followed by durably recorded funding in commit
  order. Never changes aggregate cash, credit or liability balances.
  """
  def ensure_allocated!(group) do
    if group.status != "active" and group.deposit_paid_cents <= 0 and group.credit_paid_cents <= 0 do
      :ok
    else
      Repo.transaction(fn -> reconcile_group!(group) end)
      :ok
    end
  end

  @doc """
  Brings forward every group's funding that predates room allocations (and,
  for settled groups, records their settlement dispositions). This is the
  data migration run when room accounting is introduced.
  """
  def reconcile_all! do
    Repo.transaction(fn ->
      Repo.all(Group)
      |> Enum.each(fn group -> reconcile_group!(group) end)
    end)
  end

  defp reconcile_group!(group) do
    {payments, credits} = durable_ops(group.group_id)
    payments_total = payments |> Enum.map(fn {_pid, amt} -> amt end) |> Enum.sum()
    credits_total = credits |> Enum.map(fn {_pid, amt} -> amt end) |> Enum.sum()

    legacy_cash = max(group.deposit_paid_cents - payments_total, 0)
    legacy_credit = max(group.credit_paid_cents - credits_total, 0)

    if group.status == "active" do
      reconcile_active!(group, payments, credits, legacy_cash, legacy_credit)
    else
      reconcile_settled!(group, payments, legacy_cash)
    end
  end

  defp reconcile_active!(group, payments, credits, legacy_cash, legacy_credit) do
    credit_pool =
      Repo.all(
        from ca in CreditAllocation,
          where: ca.group_id == ^group.id,
          order_by: ca.id
      )

    legacy_cash_rows = allocation_source_total(group.id, @cash_kind, nil)
    legacy_credit_rows = allocation_source_total(group.id, @credit_kind, nil)
    legacy_cash_dispositions = disposition_group_total(group.id, nil)
    legacy_cash_moved = moved_out_total(group.id, @cash_kind)
    legacy_credit_moved = moved_out_total(group.id, @credit_kind)

    legacy_cash_left =
      max(legacy_cash - legacy_cash_rows - legacy_cash_dispositions - legacy_cash_moved, 0)

    legacy_credit_left = max(legacy_credit - legacy_credit_rows - legacy_credit_moved, 0)

    cash_events = if legacy_cash_left > 0, do: [event(@cash_kind, legacy_cash_left)], else: []

    {credit_events, pool, _left} = draw_credit(credit_pool, legacy_credit_left, nil)

    payment_events =
      Enum.flat_map(payments, fn {pid, amount} ->
        remaining =
          max(
            amount - allocation_source_total(@cash_kind, pid) -
              disposition_source_total(pid, nil),
            0
          )

        if remaining > 0, do: [event(@cash_kind, remaining, pid)], else: []
      end)

    {credit_app_events, _pool} =
      Enum.map_reduce(credits, pool, fn {pid, amount}, pool ->
        remaining = max(amount - allocation_source_total(@credit_kind, pid), 0)

        if remaining > 0 do
          {taken, pool, _left} = draw_credit(pool, remaining, pid)
          {taken, pool}
        else
          {[], pool}
        end
      end)

    events = cash_events ++ credit_events ++ payment_events ++ List.flatten(credit_app_events)

    if events != [] do
      allocate!(group, events)
    end

    Repo.delete_all(from ca in CreditAllocation, where: ca.group_id == ^group.id)

    :ok
  end

  defp reconcile_settled!(group, payments, legacy_cash) do
    case settlement_kind(group) do
      nil ->
        :ok

      kind ->
        legacy_left =
          max(
            legacy_cash - disposition_group_total(group.id, nil) -
              moved_out_total(group.id, @cash_kind),
            0
          )

        legacy_row =
          if legacy_left > 0,
            do: disposition_row(group, nil, kind, legacy_left),
            else: nil

        payment_rows =
          for {pid, amount} <- payments,
              remaining = max(amount - disposition_source_total(pid, nil), 0),
              remaining > 0 do
            disposition_row(group, pid, kind, remaining)
          end

        rows = [legacy_row | payment_rows] |> Enum.reject(&is_nil/1)

        if rows != [] do
          Repo.insert_all(PaymentDisposition, rows)
        end

        :ok
    end
  end

  defp event(kind, amount, source \\ nil, lot_id \\ nil) do
    %{kind: kind, amount_cents: amount, source_operation_id: source, lot_id: lot_id}
  end

  defp disposition_row(group, source, kind, amount) do
    %{
      group_id: group.id,
      payment_operation_id: source,
      kind: kind,
      amount_cents: amount,
      lot_id: converted_lot_id(group, kind),
      inserted_at: now(),
      updated_at: now()
    }
  end

  defp now do
    NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
  end

  @doc "The settled cash's disposition kind for a legacy-era (fully settled) group."
  def settlement_kind(group) do
    cond do
      (group.converted_to_credit_cents || 0) > 0 -> "converted"
      (group.refunded_cents || 0) > 0 -> "refunded"
      (group.retained_cents || 0) > 0 -> "retained"
      true -> nil
    end
  end

  defp converted_lot_id(group, "converted"), do: durable_conversion_lot(group)
  defp converted_lot_id(_group, _kind), do: nil

  defp durable_conversion_lot(group) do
    Repo.all(from o in Operation, where: o.type == "cancel_group", order_by: o.id)
    |> Enum.find_value(fn record ->
      content = Jason.decode!(record.content)

      if content["group_id"] == group.group_id and content["refund_method"] == "hotel_credit" and
           applied?(record.result) do
        Repo.get_by(Credit.CreditLot, source_operation_id: record.operation_id)
      end
    end)
    |> case do
      nil -> nil
      lot -> lot.id
    end
  end

  @doc "Durably recorded, applied funding operations for a group, in commit order."
  def durable_ops(group_id) do
    Repo.all(
      from o in Operation,
        where: o.type in ^["record_cash_payment", "apply_hotel_credit"],
        order_by: o.id
    )
    |> Enum.reduce({[], []}, fn record, {payments, credits} ->
      content = Jason.decode!(record.content)

      if content["group_id"] == group_id and applied?(record.result) do
        amount = content["amount_cents"]

        case record.type do
          "record_cash_payment" -> {payments ++ [{record.operation_id, amount}], credits}
          _ -> {payments, credits ++ [{record.operation_id, amount}]}
        end
      else
        {payments, credits}
      end
    end)
  end

  def applied?(result_json) do
    case Jason.decode(result_json) do
      {:ok, %{"status" => "applied"}} -> true
      _ -> false
    end
  end

  defp allocation_source_total(group_id, kind, source_operation_id) do
    query =
      from(a in RoomAllocation, where: a.group_id == ^group_id and a.kind == ^kind)

    query =
      if is_nil(source_operation_id) do
        where(query, [a], is_nil(a.source_operation_id))
      else
        where(query, [a], a.source_operation_id == ^source_operation_id)
      end

    Repo.aggregate(query, :sum, :amount_cents) || 0
  end

  # Held allocation total of one kind for one source, across every group.
  defp allocation_source_total(kind, source_operation_id) do
    query = from(a in RoomAllocation, where: a.kind == ^kind)

    query =
      if is_nil(source_operation_id) do
        where(query, [a], is_nil(a.source_operation_id))
      else
        where(query, [a], a.source_operation_id == ^source_operation_id)
      end

    Repo.aggregate(query, :sum, :amount_cents) || 0
  end

  # Disposition totals recorded within one group for a source (nil = legacy).
  defp disposition_group_total(group_id, source_operation_id) do
    query = from(d in PaymentDisposition, where: d.group_id == ^group_id)

    query =
      if is_nil(source_operation_id) do
        where(query, [d], is_nil(d.payment_operation_id))
      else
        where(query, [d], d.payment_operation_id == ^source_operation_id)
      end

    Repo.aggregate(query, :sum, :amount_cents) || 0
  end

  # Legacy (unattributed) funding of `kind` that transfers moved out of a group.
  defp moved_out_total(group_id, kind) do
    Repo.aggregate(
      from(m in LegacyFundingMove,
        where: m.origin_group_id == ^group_id and m.kind == ^kind
      ),
      :sum,
      :amount_cents
    ) || 0
  end

  @doc "Settled/reduced/charged-back totals for a cash source (nil = legacy)."
  def disposition_source_total(source_operation_id, kind \\ nil)

  def disposition_source_total(source_operation_id, kind) do
    query =
      if is_nil(source_operation_id) do
        from(d in PaymentDisposition, where: is_nil(d.payment_operation_id))
      else
        from(d in PaymentDisposition,
          where: d.payment_operation_id == ^source_operation_id
        )
      end

    query =
      if kind do
        where(query, [d], d.kind == ^kind)
      else
        query
      end

    Repo.aggregate(query, :sum, :amount_cents) || 0
  end

  # ------------------------------------------------------------------
  # Legacy credit pool (credit_allocations from before room accounting)
  # ------------------------------------------------------------------

  defp draw_credit(pool, need, source) do
    {events, rest, left} =
      Enum.reduce(pool, {[], [], need}, fn ca, {acc, rest, left} ->
        cond do
          left <= 0 ->
            {acc, [ca | rest], left}

          left >= ca.amount_cents ->
            {acc ++ [event(@credit_kind, ca.amount_cents, source, ca.lot_id)], rest,
             left - ca.amount_cents}

          true ->
            take = left
            remaining = %{ca | amount_cents: ca.amount_cents - take}
            {acc ++ [event(@credit_kind, take, source, ca.lot_id)], [remaining | rest], 0}
        end
      end)

    {events, Enum.reverse(rest), left}
  end

  # ------------------------------------------------------------------
  # Settlement of selected rooms
  # ------------------------------------------------------------------

  @doc """
  Settles the selected rooms' allocated funding using the given date, policy,
  refund method and bonus/restoration rules. Returns
  `{refunded_cents, retained_cents, converted_principal_cents, credit_issued_cents}`.
  """
  def settle_rooms!(source_operation_id, group, rooms, occurred, method, refundable?) do
    room_ids = Enum.map(rooms, & &1.id)

    rows =
      Repo.all(
        from a in RoomAllocation,
          where: a.group_id == ^group.id and a.room_id in ^room_ids,
          order_by: a.id
      )

    cash_rows = Enum.filter(rows, &(&1.kind == @cash_kind))
    credit_rows = Enum.filter(rows, &(&1.kind == @credit_kind))
    cash_total = cash_rows |> Enum.map(& &1.amount_cents) |> Enum.sum()

    {refunded, retained, converted, credit_issued, lot} =
      cond do
        refundable? and method == "hotel_credit" and cash_total > 0 ->
          lot_amount = bonus_value(cash_total)
          expires_on = Date.add(occurred, 365)
          lot = Credit.issue_lot!(group.guest_id, source_operation_id, lot_amount, expires_on)
          {0, 0, cash_total, lot_amount, lot}

        refundable? and method == "hotel_credit" ->
          {0, 0, 0, 0, nil}

        refundable? ->
          {cash_total, 0, 0, 0, nil}

        true ->
          {0, cash_total, 0, 0, nil}
      end

    if cash_total > 0 do
      kind = cash_settlement_kind(refunded, retained, converted)

      cash_rows
      |> Enum.group_by(& &1.source_operation_id, & &1.amount_cents)
      |> Enum.each(fn {source, amounts} ->
        Repo.insert!(%PaymentDisposition{
          group_id: group.id,
          payment_operation_id: source,
          kind: kind,
          amount_cents: Enum.sum(amounts),
          lot_id: if(lot, do: lot.id)
        })
      end)
    end

    if refundable? do
      Credit.restore_for_rooms!(credit_rows, occurred)
    else
      Credit.consume_for_rooms!(credit_rows)
    end

    Repo.delete_all(
      from a in RoomAllocation,
        where: a.id in ^Enum.map(rows, & &1.id)
    )

    Repo.update_all(
      from(r in Room, where: r.id in ^room_ids),
      set: [status: "cancelled"]
    )

    {refunded, retained, converted, credit_issued}
  end

  defp cash_settlement_kind(refunded, _retained, _converted) when refunded > 0, do: "refunded"
  defp cash_settlement_kind(_refunded, retained, _converted) when retained > 0, do: "retained"
  defp cash_settlement_kind(_refunded, _retained, _converted), do: "converted"

  # ------------------------------------------------------------------
  # Transfers between groups
  # ------------------------------------------------------------------

  @doc """
  Moves `amount` of held funding from the source group's active rooms to the
  destination group's active rooms without settling or revaluing anything.

  Draws from the source's allocations in reverse allocation order (most
  recently created first) regardless of funding kind. Fills the destination's
  rooms in their original order, preserving the order in which the units were
  drawn. Every moved unit keeps its provenance: cash keeps its payment
  operation identity and hotel credit keeps its original lot.
  """
  def transfer!(source, destination, amount) do
    rows =
      Repo.all(
        from a in RoomAllocation,
          where: a.group_id == ^source.id and a.room_id in ^active_room_ids(source),
          order_by: [desc: a.id]
      )

    {chunks, deletions, updates, _left} = draw_transfer(rows, amount)

    Repo.delete_all(from a in RoomAllocation, where: a.id in ^deletions)

    for {id, remaining} <- updates do
      Repo.update_all(
        from(a in RoomAllocation, where: a.id == ^id),
        set: [amount_cents: remaining]
      )
    end

    inserts = place_transfer(destination, chunks)

    if inserts != [] do
      Repo.insert_all(RoomAllocation, inserts)
    end

    record_transfer_participation!(chunks)
    record_legacy_moves!(source, chunks)

    :ok
  end

  defp active_room_ids(group) do
    group.rooms
    |> Enum.filter(&(&1.status == "active"))
    |> Enum.map(& &1.id)
  end

  defp draw_transfer(rows, amount) do
    Enum.reduce_while(rows, {[], [], [], amount}, fn row, {chunks, deletions, updates, left} ->
      chunk = fn take ->
        %{
          kind: row.kind,
          source_operation_id: row.source_operation_id,
          lot_id: row.lot_id,
          amount_cents: take
        }
      end

      cond do
        left <= 0 ->
          {:halt, {chunks, deletions, updates, left}}

        left >= row.amount_cents ->
          {:cont,
           {chunks ++ [chunk.(row.amount_cents)], deletions ++ [row.id], updates,
            left - row.amount_cents}}

        true ->
          {:halt, {chunks ++ [chunk.(left)], deletions, [{row.id, row.amount_cents - left}], 0}}
      end
    end)
  end

  defp place_transfer(destination, chunks) do
    funded =
      funding_by_room(destination)
      |> Map.new(fn {room_id, kinds} ->
        {room_id, Map.get(kinds, @cash_kind, 0) + Map.get(kinds, @credit_kind, 0)}
      end)

    rooms =
      destination.rooms
      |> Enum.filter(&(&1.status == "active"))
      |> Enum.sort_by(& &1.position)

    {rows, _queue, _funded} =
      Enum.reduce(rooms, {[], chunks, funded}, fn room, {acc, queue, funded} ->
        capacity = max(room.deposit_due_cents - Map.get(funded, room.id, 0), 0)
        {placed, queue, funded} = place_into_room(room, destination.id, capacity, queue, funded)
        {acc ++ placed, queue, funded}
      end)

    rows
  end

  defp place_into_room(_room, _group_id, capacity, queue, funded) when capacity <= 0,
    do: {[], queue, funded}

  defp place_into_room(_room, _group_id, _capacity, [], funded), do: {[], [], funded}

  defp place_into_room(room, group_id, capacity, [chunk | rest], funded) do
    take = min(capacity, chunk.amount_cents)

    row = %{
      group_id: group_id,
      room_id: room.id,
      kind: chunk.kind,
      source_operation_id: chunk.source_operation_id,
      lot_id: chunk.lot_id,
      amount_cents: take,
      inserted_at: now(),
      updated_at: now()
    }

    funded = Map.update(funded, room.id, take, &(&1 + take))

    cond do
      take >= chunk.amount_cents ->
        {placed, queue, funded} =
          place_into_room(room, group_id, capacity - take, rest, funded)

        {[row | placed], queue, funded}

      true ->
        remaining_chunk = %{chunk | amount_cents: chunk.amount_cents - take}

        {placed, queue, funded} =
          place_into_room(room, group_id, capacity - take, [remaining_chunk | rest], funded)

        {[row | placed], queue, funded}
    end
  end

  # Remembers cash payments whose held funding has been moved by at least one
  # transfer, so their statements can gain the `held_by_group` list.
  defp record_transfer_participation!(chunks) do
    payment_ids =
      chunks
      |> Enum.filter(&(&1.kind == @cash_kind and not is_nil(&1.source_operation_id)))
      |> Enum.map(& &1.source_operation_id)
      |> Enum.uniq()

    if payment_ids != [] do
      timestamp = now()

      rows =
        Enum.map(payment_ids, fn payment_id ->
          %{
            payment_operation_id: payment_id,
            inserted_at: timestamp,
            updated_at: timestamp
          }
        end)

      Repo.insert_all(TransferParticipation, rows,
        on_conflict: :nothing,
        conflict_target: [:payment_operation_id]
      )
    end

    :ok
  end

  defp record_legacy_moves!(source, chunks) do
    chunks
    |> Enum.filter(&is_nil(&1.source_operation_id))
    |> Enum.group_by(& &1.kind, & &1.amount_cents)
    |> Enum.each(fn {kind, amounts} ->
      Repo.insert!(%LegacyFundingMove{
        origin_group_id: source.id,
        kind: kind,
        amount_cents: Enum.sum(amounts)
      })
    end)
  end

  # ------------------------------------------------------------------
  # Reducing recorded cash
  # ------------------------------------------------------------------

  @doc """
  Removes `amount` of the payment's held allocations in reverse fill order
  across every group and records the reduction. Callers have already
  validated the amount. Returns the ids of the groups whose allocations
  changed.
  """
  def reduce_cash!(disposition_group, payment_operation_id, amount) do
    rows =
      Repo.all(
        from a in RoomAllocation,
          where: a.kind == @cash_kind and a.source_operation_id == ^payment_operation_id,
          order_by: [desc: a.id]
      )

    {updates, deletions, group_ids, _} =
      Enum.reduce_while(rows, {[], [], [], amount}, fn row, {upd, del, groups, left} ->
        cond do
          left <= 0 ->
            {:halt, {upd, del, groups, left}}

          left >= row.amount_cents ->
            {:cont, {upd, del ++ [row.id], [row.group_id | groups], left - row.amount_cents}}

          true ->
            {:halt, {[{row.id, row.amount_cents - left} | upd], del, [row.group_id | groups], 0}}
        end
      end)

    for {id, remaining} <- updates do
      Repo.update_all(
        from(a in RoomAllocation, where: a.id == ^id),
        set: [amount_cents: remaining]
      )
    end

    Repo.delete_all(from a in RoomAllocation, where: a.id in ^deletions)

    Repo.insert!(%PaymentDisposition{
      group_id: disposition_group.id,
      payment_operation_id: payment_operation_id,
      kind: "reduced",
      amount_cents: amount,
      lot_id: nil
    })

    group_ids |> Enum.reverse() |> Enum.uniq()
  end

  # ------------------------------------------------------------------
  # Charging back a payment
  # ------------------------------------------------------------------

  @doc """
  Reclassifies every remaining disposition of the payment to charged back and
  revokes the credit entitlement its converted principal created. Returns
  `{charged_back_cents, held_group_ids, moved_by_group}` where
  `moved_by_group` maps each affected group id to the refunded, retained and
  converted amounts that were moved away from it.
  """
  def charge_back!(group, payment_operation_id) do
    held_rows =
      Repo.all(
        from a in RoomAllocation,
          where: a.kind == @cash_kind and a.source_operation_id == ^payment_operation_id
      )

    held = held_rows |> Enum.map(& &1.amount_cents) |> Enum.sum()
    held_group_ids = held_rows |> Enum.map(& &1.group_id) |> Enum.uniq()
    Repo.delete_all(from a in RoomAllocation, where: a.id in ^Enum.map(held_rows, & &1.id))

    settled =
      Repo.all(
        from d in PaymentDisposition,
          where:
            d.payment_operation_id == ^payment_operation_id and
              d.kind in ^["refunded", "retained", "converted"]
      )

    refunded = counted_total(settled, "refunded")
    retained = counted_total(settled, "retained")
    converted = counted_total(settled, "converted")

    moved_by_group =
      settled
      |> Enum.group_by(& &1.group_id)
      |> Map.new(fn {group_id, rows} ->
        {group_id,
         %{
           "refunded" => counted_total(rows, "refunded"),
           "retained" => counted_total(rows, "retained"),
           "converted" => counted_total(rows, "converted")
         }}
      end)

    if converted > 0 do
      revoke_converted_entitlements!(payment_operation_id, settled)
    end

    Repo.delete_all(from d in PaymentDisposition, where: d.id in ^Enum.map(settled, & &1.id))

    total = held + refunded + retained + converted

    if total > 0 do
      Repo.insert!(%PaymentDisposition{
        group_id: group.id,
        payment_operation_id: payment_operation_id,
        kind: "charged_back",
        amount_cents: total,
        lot_id: nil
      })
    end

    {total, held_group_ids, moved_by_group}
  end

  defp revoke_converted_entitlements!(payment_operation_id, settled) do
    settled
    |> Enum.filter(&(&1.kind == "converted"))
    |> Enum.map(& &1.lot_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(fn lot_id ->
      entitlement = Credit.entitlement_for_payment(lot_id, payment_operation_id)

      if entitlement > 0 do
        Credit.revoke_entitlement!(lot_id, entitlement)
      end
    end)
  end

  defp counted_total(rows, kind) do
    rows |> Enum.filter(&(&1.kind == kind)) |> Enum.map(& &1.amount_cents) |> Enum.sum()
  end

  # ------------------------------------------------------------------
  # Cumulative disposition totals (ledger)
  # ------------------------------------------------------------------

  def disposition_total(kind) do
    Repo.aggregate(
      from(d in PaymentDisposition, where: d.kind == ^kind),
      :sum,
      :amount_cents
    ) || 0
  end

  def source_disposition_total(source_operation_id, kind) do
    Repo.aggregate(
      from(d in PaymentDisposition,
        where: d.payment_operation_id == ^source_operation_id and d.kind == ^kind
      ),
      :sum,
      :amount_cents
    ) || 0
  end

  # ------------------------------------------------------------------
  # Payment reconciliation read
  # ------------------------------------------------------------------

  @doc """
  Current disposition of cash from one durably recorded, applied cash
  payment. Returns `:not_found`, `:not_payment` or `{:ok, map}`.
  """
  def reconcile_payment(payment_operation_id) do
    case Repo.get_by(Operation, operation_id: payment_operation_id) do
      nil ->
        :not_found

      record ->
        result = Jason.decode!(record.result)
        content = Jason.decode!(record.content)

        if record.type == "record_cash_payment" and result["status"] == "applied" do
          statement = %{
            "payment_operation_id" => payment_operation_id,
            "original_group_id" => content["group_id"],
            "recorded_cents" => content["amount_cents"],
            "held_cents" => source_allocation_total(payment_operation_id),
            "refunded_cents" => source_disposition_total(payment_operation_id, "refunded"),
            "retained_cents" => source_disposition_total(payment_operation_id, "retained"),
            "converted_to_credit_cents" =>
              source_disposition_total(payment_operation_id, "converted"),
            "reduced_cents" => source_disposition_total(payment_operation_id, "reduced"),
            "charged_back_cents" => source_disposition_total(payment_operation_id, "charged_back")
          }

          if transferred?(payment_operation_id) do
            {:ok, Map.put(statement, "held_by_group", held_by_group(payment_operation_id))}
          else
            {:ok, statement}
          end
        else
          :not_payment
        end
    end
  end

  @doc "True once any funding from the payment has participated in a transfer."
  def transferred?(payment_operation_id) do
    Repo.exists?(
      from t in TransferParticipation,
        where: t.payment_operation_id == ^payment_operation_id
    )
  end

  @doc "Current held cash of a payment per group, ordered by group_id."
  def held_by_group(payment_operation_id) do
    Repo.all(
      from a in RoomAllocation,
        join: g in Group,
        on: a.group_id == g.id,
        where: a.kind == @cash_kind and a.source_operation_id == ^payment_operation_id,
        group_by: g.group_id,
        order_by: [asc: g.group_id],
        select: {g.group_id, sum(a.amount_cents)}
    )
    |> Enum.map(fn {group_id, amount} -> %{"group_id" => group_id, "amount_cents" => amount} end)
  end

  defp source_allocation_total(source_operation_id) do
    Repo.aggregate(
      from(a in RoomAllocation,
        where: a.kind == @cash_kind and a.source_operation_id == ^source_operation_id
      ),
      :sum,
      :amount_cents
    ) || 0
  end

  # ------------------------------------------------------------------
  # Room backfill used by the room-accounting migration
  # ------------------------------------------------------------------

  @doc """
  Fills room lodging, deposit and status columns from group data. Only needed
  for rooms created before room-level accounting existed.
  """
  def backfill_rooms! do
    Repo.all(Group)
    |> Enum.each(fn group ->
      nights = Date.diff(group.departure_on, group.arrival_on)

      Repo.all(from r in Room, where: r.group_id == ^group.id)
      |> Enum.each(fn room ->
        lodging = room_lodging(nights, room.nightly_rate_cents)
        deposit = room_deposit(nights, room.nightly_rate_cents, group.rate_plan)
        status = if group.status == "active", do: "active", else: "cancelled"

        Repo.update_all(
          from(r in Room, where: r.id == ^room.id),
          set: [lodging_cents: lodging, deposit_due_cents: deposit, status: status]
        )
      end)
    end)

    :ok
  end
end
