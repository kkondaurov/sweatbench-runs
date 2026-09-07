defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentAdjustments do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    alter table(:credit_allocations) do
      add :room_id, references(:rooms, on_delete: :delete_all)
      add :funding_operation_id, :string
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:cash_payments) do
      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :restrict),
          null: false

      add :payment_operation_id, :string
      add :recorded_cents, :integer, null: false
      add :funding_order, :integer, null: false
    end

    create unique_index(:cash_payments, [:payment_operation_id])
    create index(:cash_payments, [:group_id, :funding_order])

    create table(:cash_allocations) do
      add :cash_payment_id, references(:cash_payments, on_delete: :restrict), null: false
      add :room_id, references(:rooms, on_delete: :restrict), null: false
      add :amount_cents, :integer, null: false
      add :disposition, :string, null: false
      add :credit_lot_id, references(:credit_lots, on_delete: :restrict)
    end

    create index(:cash_allocations, [:cash_payment_id, :disposition])
    create index(:cash_allocations, [:room_id, :disposition])

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots, on_delete: :restrict), null: false
      add :cash_payment_id, references(:cash_payments, on_delete: :restrict), null: false
      add :principal_cents, :integer, null: false
      add :entitlement_cents, :integer, null: false
      add :clawed_back, :boolean, null: false, default: false
    end

    create index(:credit_entitlements, [:cash_payment_id])
    create index(:credit_entitlements, [:credit_lot_id])

    flush()

    execute("""
    UPDATE rooms
    SET status = (SELECT status FROM groups WHERE groups.group_id = rooms.group_id),
        lodging_total_cents = nightly_rate_cents * CAST(
          julianday((SELECT departure_on FROM groups WHERE groups.group_id = rooms.group_id)) -
          julianday((SELECT arrival_on FROM groups WHERE groups.group_id = rooms.group_id)) AS INTEGER
        ),
        deposit_due_cents = CASE
          WHEN (SELECT rate_plan FROM groups WHERE groups.group_id = rooms.group_id) = 'advance_purchase'
            THEN nightly_rate_cents * CAST(
              julianday((SELECT departure_on FROM groups WHERE groups.group_id = rooms.group_id)) -
              julianday((SELECT arrival_on FROM groups WHERE groups.group_id = rooms.group_id)) AS INTEGER
            )
          ELSE CAST((nightly_rate_cents * CAST(
            julianday((SELECT departure_on FROM groups WHERE groups.group_id = rooms.group_id)) -
            julianday((SELECT arrival_on FROM groups WHERE groups.group_id = rooms.group_id)) AS INTEGER
          ) * 20 + 50) / 100 AS INTEGER)
        END
    """)

    flush()
    backfill_funding()

    execute("""
    UPDATE groups
    SET lodging_total_cents = COALESCE((
          SELECT SUM(lodging_total_cents) FROM rooms
          WHERE rooms.group_id = groups.group_id AND rooms.status = 'active'
        ), 0),
        deposit_due_cents = COALESCE((
          SELECT SUM(deposit_due_cents) FROM rooms
          WHERE rooms.group_id = groups.group_id AND rooms.status = 'active'
        ), 0),
        cash_paid_cents = COALESCE((
          SELECT SUM(cash_paid_cents) FROM rooms
          WHERE rooms.group_id = groups.group_id AND rooms.status = 'active'
        ), 0),
        credit_paid_cents = COALESCE((
          SELECT SUM(credit_paid_cents) FROM rooms
          WHERE rooms.group_id = groups.group_id AND rooms.status = 'active'
        ), 0),
        deposit_paid_cents = COALESCE((
          SELECT SUM(cash_paid_cents + credit_paid_cents) FROM rooms
          WHERE rooms.group_id = groups.group_id AND rooms.status = 'active'
        ), 0)
    """)

    create index(:credit_allocations, [:room_id])
    create index(:credit_allocations, [:funding_operation_id])
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:cash_allocations)
    drop table(:cash_payments)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:credit_allocations) do
      remove :funding_operation_id
      remove :room_id
    end

    alter table(:rooms) do
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :deposit_due_cents
      remove :lodging_total_cents
      remove :status
    end
  end

  # This is intentionally an upgrade backfill rather than application code. It reconstructs the
  # ordering boundary introduced by durable operations: one legacy cash/credit block, followed by
  # recorded funding in commit order. Existing credit-allocation IDs preserve lot consumption order.
  defp backfill_funding do
    %{rows: groups} =
      repo().query!("""
      SELECT group_id, status, cash_paid_cents, credit_paid_cents,
             refunded_cents, retained_cents, cash_converted_to_credit_cents
      FROM groups ORDER BY group_id
      """)

    Enum.each(groups, &backfill_group/1)
  end

  defp backfill_group([
         group_id,
         status,
         cash_paid,
         credit_paid,
         refunded,
         retained,
         converted
       ]) do
    rooms = room_rows(group_id)
    durable = durable_funding(group_id)
    durable_cash = sum_type(durable, "record_cash_payment")
    durable_credit = sum_type(durable, "apply_hotel_credit")

    legacy_events =
      []
      |> maybe_event({:cash, nil, max(cash_paid - durable_cash, 0), 0})
      |> maybe_event({:credit, nil, max(credit_paid - durable_credit, 0), 0})

    durable_events =
      Enum.map(durable, fn [order, operation_id, type, amount] ->
        kind = if type == "record_cash_payment", do: :cash, else: :credit
        {kind, operation_id, amount, order}
      end)

    existing_credit = credit_rows(group_id)
    repo().query!("DELETE FROM credit_allocations WHERE group_id = ?", [group_id])

    settlement = settlement_queue(refunded, retained, converted)

    {rooms, _credit, _settlement, converted_allocations} =
      Enum.reduce(legacy_events ++ durable_events, {rooms, existing_credit, settlement, []}, fn
        {:cash, operation_id, amount, order},
        {room_state, credit_state, settlement_state, converted_acc} ->
          payment_id = insert_cash_payment(group_id, operation_id, amount, order)

          {new_rooms, new_settlement, newly_converted} =
            allocate_cash(payment_id, amount, room_state, status, settlement_state, group_id)

          {new_rooms, credit_state, new_settlement, converted_acc ++ newly_converted}

        {:credit, operation_id, amount, _order},
        {room_state, credit_state, settlement_state, converted_acc} ->
          {new_rooms, new_credit} =
            allocate_credit(group_id, operation_id, amount, room_state, credit_state, status)

          {new_rooms, new_credit, settlement_state, converted_acc}
      end)

    if status == "active" do
      Enum.each(rooms, fn room ->
        repo().query!(
          "UPDATE rooms SET cash_paid_cents = ?, credit_paid_cents = ? WHERE id = ?",
          [room.cash, room.credit, room.id]
        )
      end)
    end

    backfill_entitlements(group_id, converted_allocations)
  end

  defp room_rows(group_id) do
    %{rows: rows} =
      repo().query!(
        "SELECT id, deposit_due_cents FROM rooms WHERE group_id = ? ORDER BY position",
        [group_id]
      )

    Enum.map(rows, fn [id, due] -> %{id: id, remaining: due, cash: 0, credit: 0} end)
  end

  defp durable_funding(group_id) do
    %{rows: rows} =
      repo().query!(
        """
        SELECT commit_order, operation_id, operation_type,
               CAST(json_extract(result, '$.amount_cents') AS INTEGER)
        FROM partner_operation_records
        WHERE operation_type IN ('record_cash_payment', 'apply_hotel_credit')
          AND json_extract(result, '$.status') = 'applied'
          AND json_extract(result, '$.group_id') = ?
        ORDER BY commit_order
        """,
        [group_id]
      )

    rows
  end

  defp credit_rows(group_id) do
    %{rows: rows} =
      repo().query!(
        "SELECT id, credit_lot_id, amount_cents FROM credit_allocations WHERE group_id = ? ORDER BY id",
        [group_id]
      )

    Enum.map(rows, fn [_id, lot_id, amount] -> %{lot_id: lot_id, remaining: amount} end)
  end

  defp sum_type(rows, type) do
    rows
    |> Enum.filter(fn [_order, _id, row_type, _amount] -> row_type == type end)
    |> Enum.reduce(0, fn [_order, _id, _type, amount], total -> total + amount end)
  end

  defp maybe_event(events, {_kind, _id, 0, _order}), do: events
  defp maybe_event(events, event), do: events ++ [event]

  defp settlement_queue(refunded, retained, converted) do
    [{"refunded", refunded}, {"retained", retained}, {"converted", converted}]
  end

  defp insert_cash_payment(group_id, operation_id, amount, order) do
    %{rows: [[id]]} =
      repo().query!(
        """
        INSERT INTO cash_payments
          (group_id, payment_operation_id, recorded_cents, funding_order)
        VALUES (?, ?, ?, ?) RETURNING id
        """,
        [group_id, operation_id, amount, order]
      )

    id
  end

  defp allocate_cash(payment_id, amount, rooms, "active", settlement, _group_id) do
    {rooms, pieces} = fill_rooms(rooms, amount, :cash)

    Enum.each(pieces, fn {room_id, cents} ->
      insert_cash_allocation(payment_id, room_id, cents, "held", nil)
    end)

    {rooms, settlement, []}
  end

  defp allocate_cash(payment_id, amount, rooms, _cancelled, settlement, group_id) do
    {rooms, pieces} = fill_rooms(rooms, amount, :none)
    lot_id = converted_lot_id(group_id)

    {settlement, converted} =
      Enum.reduce(pieces, {settlement, []}, fn {room_id, cents}, {queue, converted_acc} ->
        {chunks, new_queue} = take_settlement(queue, cents)

        new_converted =
          Enum.reduce(chunks, converted_acc, fn {disposition, chunk}, acc ->
            linked_lot = if disposition == "converted", do: lot_id, else: nil
            insert_cash_allocation(payment_id, room_id, chunk, disposition, linked_lot)

            if disposition == "converted", do: acc ++ [{payment_id, chunk, linked_lot}], else: acc
          end)

        {new_queue, new_converted}
      end)

    {rooms, settlement, converted}
  end

  defp allocate_credit(group_id, operation_id, amount, rooms, credit, "active") do
    {rooms, room_pieces} = fill_rooms(rooms, amount, :credit)
    {lot_pieces, credit} = take_credit(credit, amount)

    distribute_credit(group_id, operation_id, room_pieces, lot_pieces)
    {rooms, credit}
  end

  defp allocate_credit(_group_id, _operation_id, amount, rooms, credit, _cancelled) do
    {rooms, _pieces} = fill_rooms(rooms, amount, :none)
    {rooms, credit}
  end

  defp fill_rooms(rooms, amount, kind), do: fill_rooms(rooms, amount, kind, [])
  defp fill_rooms(rooms, 0, _kind, pieces), do: {rooms, pieces}

  defp fill_rooms([room | rest], amount, kind, pieces) do
    used = min(room.remaining, amount)

    updated = %{
      room
      | remaining: room.remaining - used,
        cash: room.cash + if(kind == :cash, do: used, else: 0),
        credit: room.credit + if(kind == :credit, do: used, else: 0)
    }

    new_pieces = if used > 0, do: pieces ++ [{room.id, used}], else: pieces

    if amount == used do
      {[updated | rest], new_pieces}
    else
      {filled_rest, final_pieces} = fill_rooms(rest, amount - used, kind, new_pieces)
      {[updated | filled_rest], final_pieces}
    end
  end

  defp take_credit(credit, amount), do: take_credit(credit, amount, [])
  defp take_credit(credit, 0, pieces), do: {pieces, credit}

  defp take_credit([entry | rest], amount, pieces) do
    used = min(entry.remaining, amount)
    entry = %{entry | remaining: entry.remaining - used}
    remaining_entries = if entry.remaining == 0, do: rest, else: [entry | rest]
    take_credit(remaining_entries, amount - used, pieces ++ [{entry.lot_id, used}])
  end

  defp distribute_credit(group_id, operation_id, rooms, lots) do
    distribute_credit(group_id, operation_id, rooms, lots, nil)
  end

  defp distribute_credit(_group_id, _operation_id, [], _lots, _unused), do: :ok

  defp distribute_credit(group_id, operation_id, [{room_id, room_amount} | rooms], lots, _unused) do
    {used_lots, remaining_lots} = take_pairs(lots, room_amount, [])

    Enum.each(used_lots, fn {lot_id, amount} ->
      repo().query!(
        """
        INSERT INTO credit_allocations
          (group_id, credit_lot_id, room_id, funding_operation_id, amount_cents, inserted_at, updated_at)
        VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        """,
        [group_id, lot_id, room_id, operation_id, amount]
      )
    end)

    distribute_credit(group_id, operation_id, rooms, remaining_lots, nil)
  end

  defp take_pairs(pairs, 0, used), do: {used, pairs}

  defp take_pairs([{key, available} | rest], amount, used) do
    take = min(available, amount)
    remaining = if available == take, do: rest, else: [{key, available - take} | rest]
    take_pairs(remaining, amount - take, used ++ [{key, take}])
  end

  defp take_settlement(queue, amount), do: take_settlement(queue, amount, [])
  defp take_settlement(queue, 0, chunks), do: {chunks, queue}

  defp take_settlement([{_disposition, available} | rest], amount, chunks) when available == 0,
    do: take_settlement(rest, amount, chunks)

  defp take_settlement([{disposition, available} | rest], amount, chunks) do
    take = min(available, amount)
    remaining = if available == take, do: rest, else: [{disposition, available - take} | rest]
    take_settlement(remaining, amount - take, chunks ++ [{disposition, take}])
  end

  defp insert_cash_allocation(payment_id, room_id, amount, disposition, lot_id) do
    repo().query!(
      """
      INSERT INTO cash_allocations
        (cash_payment_id, room_id, amount_cents, disposition, credit_lot_id)
      VALUES (?, ?, ?, ?, ?)
      """,
      [payment_id, room_id, amount, disposition, lot_id]
    )
  end

  defp converted_lot_id(group_id) do
    case repo().query!(
           """
           SELECT lot.id
           FROM credit_lots lot
           JOIN partner_operation_records operation
             ON operation.operation_id = lot.source_operation_id
           WHERE json_extract(operation.submission, '$.group_id') = ?
             AND operation.operation_type IN ('cancel_group', 'cancel_rooms')
           ORDER BY lot.id LIMIT 1
           """,
           [group_id]
         ).rows do
      [[id]] -> id
      [] -> nil
    end
  end

  defp backfill_entitlements(_group_id, []), do: :ok

  defp backfill_entitlements(_group_id, converted_allocations) do
    converted_allocations
    |> Enum.group_by(fn {_payment_id, _amount, lot_id} -> lot_id end)
    |> Enum.each(fn
      {nil, _entries} ->
        :ok

      {lot_id, entries} ->
        entries
        |> Enum.chunk_by(fn {payment_id, _amount, _lot_id} -> payment_id end)
        |> Enum.reduce(0, fn payment_entries, prior_principal ->
          payment_id = payment_entries |> hd() |> elem(0)
          principal = Enum.sum(Enum.map(payment_entries, &elem(&1, 1)))
          total_principal = prior_principal + principal
          entitlement = principal + bonus(total_principal) - bonus(prior_principal)

          repo().query!(
            """
            INSERT INTO credit_entitlements
              (credit_lot_id, cash_payment_id, principal_cents, entitlement_cents, clawed_back)
            VALUES (?, ?, ?, ?, 0)
            """,
            [lot_id, payment_id, principal, entitlement]
          )

          total_principal
        end)
    end)
  end

  defp bonus(cents), do: div(cents * 10 + 50, 100)
end
