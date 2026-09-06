defmodule GroupStay.Migrations.RoomAccountingBackfill do
  @moduledoc """
  Brings existing funding forward into room allocations when room accounting
  is introduced.

  Funding without a durable operation record becomes one unattributed senior
  block per group: its aggregate cash fills the rooms first, then its
  hotel-credit lots in original consumption order. Recorded funding — applied
  cash payments and hotel-credit applications — is classified by the retained
  operation type and allocated after the senior block, in durable-record
  commit order regardless of `occurred_on`.

  Rooms receive their status and deposit amounts, cancelled groups' totals
  become the empty sums over their (absent) active rooms, and funding for
  cancelled groups with recorded payments is carried forward with its settled
  disposition. No aggregate cash, credit, or liability balance changes.

  Groups whose rooms already carry deposit amounts are left untouched, so the
  backfill can be re-run safely.
  """

  import Ecto.Query

  alias GroupStay.Finance.CreditApplication
  alias GroupStay.Finance.CreditLot
  alias GroupStay.Finance.RoomAllocation
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Operations.OperationRecord
  alias GroupStay.Repo

  @flexible_deposit_percent 20

  @doc """
  Backfills room accounting for every group whose rooms do not carry deposit
  amounts yet.
  """
  def run do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    records = load_records()
    lots_by_source = lots_by_source()

    for group <- pending_groups() do
      rooms =
        Repo.all(from r in Room, where: r.group_id == ^group.id, order_by: [asc: r.position])

      backfill_group(group, rooms, records, lots_by_source, now)
    end

    :ok
  end

  defp pending_groups do
    Room
    |> where([r], r.deposit_due_cents == 0)
    |> distinct(true)
    |> select([r], r.group_id)
    |> Repo.all()
    |> Enum.map(&Repo.get!(Group, &1))
  end

  defp load_records do
    OperationRecord
    |> order_by([r], asc: r.id)
    |> Repo.all()
    |> Enum.map(fn record ->
      %{
        id: record.id,
        type: record.type,
        operation_id: record.operation_id,
        result: Jason.decode!(record.result)
      }
    end)
  end

  defp lots_by_source do
    CreditLot
    |> Repo.all()
    |> Map.new(fn lot -> {lot.source_operation_id, lot.id} end)
  end

  defp backfill_group(group, rooms, records, lots_by_source, now) do
    rooms = with_deposit_due(rooms, group)

    if group.status == "active" do
      backfill_active_group(group, rooms, records, now)
    else
      backfill_cancelled_group(group, rooms, records, lots_by_source, now)
    end
  end

  # Active groups: carry funding forward as held allocations.

  defp backfill_active_group(group, rooms, records, now) do
    group_records = records_for(records, group.group_id)
    cash_ops = applied_ops(group_records, "record_cash_payment")
    credit_ops = applied_ops(group_records, "apply_hotel_credit")

    legacy_cash = group.cash_paid_cents - total_amount(cash_ops)
    legacy_credit = group.credit_paid_cents - total_amount(credit_ops)

    fundings =
      ([{:cash, nil, legacy_cash}, {:credit, nil, legacy_credit}] ++
         Enum.map(group_records, &funding_of/1))
      |> Enum.reject(&is_nil/1)

    {rooms, rows, _applications} =
      apply_fundings(rooms, fundings, active_applications(group.id), "held", now)

    Repo.insert_all(RoomAllocation, rows)
    update_rooms(rooms, "active", now)
  end

  defp funding_of(%{type: "record_cash_payment", result: %{"status" => "applied"}} = record) do
    {:cash, record.operation_id, record.result["amount_cents"]}
  end

  defp funding_of(%{type: "apply_hotel_credit", result: %{"status" => "applied"}} = record) do
    {:credit, record.operation_id, record.result["amount_cents"]}
  end

  defp funding_of(_record), do: nil

  # Cancelled groups: rooms keep their historical paid amounts, group totals
  # become the empty sums over active rooms, and recorded cash is carried
  # forward with its settled disposition.

  defp backfill_cancelled_group(group, rooms, records, lots_by_source, now) do
    {rooms, _rows} = fill_cash(rooms, group.cash_paid_cents, nil, "held", now)
    {rooms, _rows} = fill_credit(rooms, [{nil, group.credit_paid_cents}], nil, now)
    update_rooms(rooms, "cancelled", now)
    zero_group_totals(group)

    group_records = records_for(records, group.group_id)
    cash_ops = applied_ops(group_records, "record_cash_payment")

    cancellation =
      Enum.find(group_records, fn record ->
        record.type == "cancel_group" and record.result["status"] == "applied"
      end)

    if cash_ops != [] and cancellation != nil do
      {status, lot_id} = disposition_of(cancellation, lots_by_source)
      legacy_cash = group.cash_paid_cents - total_amount(cash_ops)

      fundings =
        [
          {:cash, nil, legacy_cash}
          | Enum.map(cash_ops, &{:cash, &1.operation_id, &1.result["amount_cents"]})
        ]

      {_rooms, rows} =
        Enum.reduce(fundings, {rooms_with_zero_paid(rooms), []}, fn
          {_kind, _operation_id, 0}, acc ->
            acc

          {:cash, operation_id, amount}, {rooms_acc, rows_acc} ->
            {rooms_acc, new_rows} = fill_cash(rooms_acc, amount, operation_id, status, now)
            {rooms_acc, rows_acc ++ with_lot(new_rows, lot_id)}
        end)

      Repo.insert_all(RoomAllocation, rows)
    end

    :ok
  end

  defp rooms_with_zero_paid(rooms) do
    Enum.map(rooms, &%{&1 | cash_paid_cents: 0, credit_paid_cents: 0})
  end

  defp with_lot(rows, nil), do: rows
  defp with_lot(rows, lot_id), do: Enum.map(rows, &Map.put(&1, :lot_id, lot_id))

  defp disposition_of(cancellation, lots_by_source) do
    result = cancellation.result

    cond do
      result["credit_issued_cents"] > 0 ->
        {"converted", Map.get(lots_by_source, cancellation.operation_id)}

      result["refunded_cents"] > 0 ->
        {"refunded", nil}

      true ->
        {"retained", nil}
    end
  end

  defp zero_group_totals(group) do
    Repo.update_all(
      from(g in Group, where: g.id == ^group.id),
      set: [
        lodging_total_cents: 0,
        deposit_due_cents: 0,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0
      ]
    )

    :ok
  end

  # Funding application

  defp apply_fundings(rooms, fundings, applications, status, now) do
    Enum.reduce(fundings, {rooms, [], applications}, fn
      {:cash, operation_id, amount}, {rooms_acc, rows_acc, apps} when amount > 0 ->
        {rooms_acc, new_rows} = fill_cash(rooms_acc, amount, operation_id, status, now)
        {rooms_acc, rows_acc ++ new_rows, apps}

      {:credit, operation_id, amount}, {rooms_acc, rows_acc, apps} when amount > 0 ->
        {segments, apps} = take_credit(apps, amount)
        {rooms_acc, new_rows} = fill_credit(rooms_acc, segments, operation_id, now)
        {rooms_acc, rows_acc ++ new_rows, apps}

      _funding, acc ->
        acc
    end)
  end

  defp fill_cash(rooms, amount, operation_id, status, now) do
    do_fill_cash(rooms, amount, operation_id, status, now, [], [])
  end

  defp do_fill_cash(rooms, 0, _operation_id, _status, _now, rooms_done, rows) do
    {rooms_done ++ rooms, Enum.reverse(rows)}
  end

  defp do_fill_cash([], _remaining, _operation_id, _status, _now, rooms_done, rows) do
    {rooms_done, Enum.reverse(rows)}
  end

  defp do_fill_cash([room | rooms], remaining, operation_id, status, now, rooms_done, rows) do
    capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
    take = min(capacity, remaining)

    if take > 0 do
      room = %{room | cash_paid_cents: room.cash_paid_cents + take}

      row = allocation_row(room, "cash", take, operation_id, nil, status, now)

      do_fill_cash(
        rooms,
        remaining - take,
        operation_id,
        status,
        now,
        rooms_done ++ [room],
        [row | rows]
      )
    else
      do_fill_cash(rooms, remaining, operation_id, status, now, rooms_done ++ [room], rows)
    end
  end

  defp fill_credit(rooms, segments, operation_id, now) do
    do_fill_credit(rooms, segments, operation_id, now, [], [])
  end

  defp do_fill_credit(rooms, [], _operation_id, _now, rooms_done, rows) do
    {rooms_done ++ rooms, Enum.reverse(rows)}
  end

  defp do_fill_credit([], _segments, _operation_id, _now, rooms_done, rows) do
    {rooms_done, Enum.reverse(rows)}
  end

  defp do_fill_credit(
         [room | rooms],
         [{lot_id, amount} | segments],
         operation_id,
         now,
         rooms_done,
         rows
       ) do
    capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
    take = min(capacity, amount)

    if take > 0 do
      room = %{room | credit_paid_cents: room.credit_paid_cents + take}

      row = allocation_row(room, "credit", take, operation_id, lot_id, "held", now)

      rooms = if capacity - take > 0, do: [room | rooms], else: rooms

      segments =
        if amount - take > 0, do: [{lot_id, amount - take} | segments], else: segments

      do_fill_credit(rooms, segments, operation_id, now, rooms_done, [row | rows])
    else
      do_fill_credit(
        rooms,
        [{lot_id, amount} | segments],
        operation_id,
        now,
        rooms_done ++ [room],
        rows
      )
    end
  end

  defp allocation_row(room, kind, amount_cents, operation_id, lot_id, status, now) do
    %{
      group_id: room.group_id,
      room_id: room.id,
      kind: kind,
      funding_operation_id: operation_id,
      lot_id: lot_id,
      amount_cents: amount_cents,
      status: status,
      inserted_at: now,
      updated_at: now
    }
  end

  # Credit-lot attribution

  defp active_applications(group_id) do
    CreditApplication
    |> where([a], a.group_id == ^group_id and a.status == "active")
    |> order_by([a], asc: fragment("rowid"))
    |> Repo.all()
    |> Enum.map(&{&1.lot_id, &1.amount_cents})
  end

  defp take_credit(applications, amount) do
    do_take_credit(applications, amount, [])
  end

  defp do_take_credit(applications, 0, acc), do: {Enum.reverse(acc), applications}
  defp do_take_credit([], _amount, acc), do: {Enum.reverse(acc), []}

  defp do_take_credit([{lot_id, available} | applications], amount, acc)
       when available <= amount do
    do_take_credit(applications, amount - available, [{lot_id, available} | acc])
  end

  defp do_take_credit([{lot_id, available} | applications], amount, acc) do
    {Enum.reverse([{lot_id, amount} | acc]), [{lot_id, available - amount} | applications]}
  end

  # Helpers

  defp records_for(records, group_id) do
    Enum.filter(records, &(&1.result["group_id"] == group_id))
  end

  defp applied_ops(records, type) do
    Enum.filter(records, &(&1.type == type and &1.result["status"] == "applied"))
  end

  defp total_amount(ops) do
    Enum.reduce(ops, 0, &(&1.result["amount_cents"] + &2))
  end

  defp with_deposit_due(rooms, group) do
    nights = Date.diff(group.departure_on, group.arrival_on)

    Enum.map(rooms, fn room ->
      %{
        room
        | deposit_due_cents: room_deposit_due(group.rate_plan, nights, room.nightly_rate_cents)
      }
    end)
  end

  defp room_deposit_due("advance_purchase", nights, nightly_rate_cents) do
    nights * nightly_rate_cents
  end

  defp room_deposit_due("flexible", nights, nightly_rate_cents) do
    div(nightly_rate_cents * nights * @flexible_deposit_percent + 50, 100)
  end

  defp update_rooms(rooms, status, now) do
    Enum.each(rooms, fn room ->
      Repo.update_all(
        from(r in Room, where: r.id == ^room.id),
        set: [
          status: status,
          deposit_due_cents: room.deposit_due_cents,
          cash_paid_cents: room.cash_paid_cents,
          credit_paid_cents: room.credit_paid_cents,
          updated_at: now
        ]
      )
    end)
  end
end
