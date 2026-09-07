defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
    end

    alter table(:groups) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:cash_payments) do
      add :operation_id, :string, null: false
      add :group_record_id, references(:groups, on_delete: :restrict), null: false
      add :recorded_cents, :integer, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cash_payments, [:operation_id])
    create index(:cash_payments, [:group_record_id])

    create table(:room_allocations) do
      add :room_id, references(:rooms, on_delete: :delete_all), null: false
      add :credit_lot_id, references(:credit_lots, on_delete: :restrict)
      add :funding_type, :string, null: false
      add :amount_cents, :integer, null: false
      add :payment_operation_id, :string
      add :allocation_order, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:room_allocations, [:room_id, :allocation_order])
    create index(:room_allocations, [:payment_operation_id])
    create index(:room_allocations, [:credit_lot_id])

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :payment_operation_id, :string
      add :issued_cents, :integer, null: false
      add :revoked_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:credit_entitlements, [:payment_operation_id])
    create index(:credit_entitlements, [:credit_lot_id])

    # The data migration below uses the newly added columns and tables through
    # direct queries, so execute the queued DDL before reading legacy rows.
    flush()

    execute("""
    UPDATE rooms
       SET lodging_total_cents = nightly_rate_cents * CAST(
             julianday((SELECT departure_on FROM groups WHERE groups.id = rooms.group_record_id)) -
             julianday((SELECT arrival_on FROM groups WHERE groups.id = rooms.group_record_id))
           AS INTEGER),
           status = CASE
             WHEN (SELECT status FROM groups WHERE groups.id = rooms.group_record_id) = 'cancelled'
             THEN 'cancelled' ELSE 'active' END
    """)

    execute("""
    UPDATE rooms
       SET deposit_due_cents = CASE
         WHEN (SELECT rate_plan FROM groups WHERE groups.id = rooms.group_record_id) = 'advance_purchase'
         THEN lodging_total_cents
         ELSE CAST((lodging_total_cents * 20 + 50) / 100 AS INTEGER)
       END
    """)

    backfill_cash_payments()
    flush()
    backfill_room_allocations()
    backfill_settled_payment_dispositions()
    backfill_credit_entitlements()

    # The new aggregate fields describe active rooms only. Historical cash
    # settlement remains in the cumulative classification columns above.
    execute("""
    UPDATE groups
       SET lodging_total_cents = 0,
           deposit_due_cents = 0,
           deposit_paid_cents = 0,
           cash_paid_cents = 0,
           credit_paid_cents = 0
     WHERE status = 'cancelled'
    """)
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:room_allocations)
    drop table(:cash_payments)

    alter table(:credit_lots), do: remove(:unrecovered_clawback_cents)

    alter table(:groups) do
      remove :cash_reduced_cents
      remove :cash_charged_back_cents
    end

    alter table(:rooms) do
      remove :status
      remove :lodging_total_cents
      remove :deposit_due_cents
    end
  end

  # Durable payment receipts are the identity boundary for all new reconciliation.
  defp backfill_cash_payments do
    execute("""
    INSERT INTO cash_payments
      (operation_id, group_record_id, recorded_cents, refunded_cents, retained_cents,
       converted_to_credit_cents, reduced_cents, charged_back_cents, inserted_at, updated_at)
    SELECT po.operation_id, g.id, json_extract(po.result, '$.amount_cents'), 0, 0, 0, 0, 0,
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM partner_operations po
      JOIN groups g ON g.group_id = json_extract(po.result, '$.group_id')
     WHERE po.operation_type = 'record_cash_payment'
       AND json_extract(po.result, '$.status') = 'applied'
     ORDER BY po.id
    """)
  end

  defp backfill_room_allocations do
    groups =
      rows("""
      SELECT id, cash_paid_cents, credit_paid_cents
        FROM groups WHERE status = 'active' ORDER BY id
      """)

    Enum.each(groups, fn [group_id, cash_paid, credit_paid] ->
      durable = durable_funding(group_id)
      durable_cash = durable |> Enum.filter(&(&1.type == "record_cash_payment")) |> sum_amounts()
      durable_credit = durable |> Enum.filter(&(&1.type == "apply_hotel_credit")) |> sum_amounts()
      legacy_cash = max(cash_paid - durable_cash, 0)
      legacy_credit = max(credit_paid - durable_credit, 0)
      credit_chunks = credit_chunks(group_id)

      {legacy_credit_items, credit_chunks} = take_credit(credit_chunks, legacy_credit, nil)

      {durable_items, _credit_chunks} =
        Enum.map_reduce(durable, credit_chunks, fn funding, chunks ->
          case funding.type do
            "record_cash_payment" ->
              {[%{type: "cash", amount: funding.amount, payment: funding.operation_id}], chunks}

            "apply_hotel_credit" ->
              take_credit(chunks, funding.amount, nil)
          end
        end)

      items =
        optional_item("cash", legacy_cash, nil) ++
          legacy_credit_items ++ List.flatten(durable_items)

      allocate_to_rooms(group_id, items)
    end)
  end

  defp durable_funding(group_id) do
    rows(
      """
      SELECT po.id, po.operation_id, po.operation_type, json_extract(po.result, '$.amount_cents')
        FROM partner_operations po
        JOIN groups g ON g.group_id = json_extract(po.result, '$.group_id')
       WHERE g.id = ?
         AND po.operation_type IN ('record_cash_payment', 'apply_hotel_credit')
         AND json_extract(po.result, '$.status') = 'applied'
       ORDER BY po.id
      """,
      [group_id]
    )
    |> Enum.map(fn [_id, operation_id, type, amount] ->
      %{operation_id: operation_id, type: type, amount: amount}
    end)
  end

  defp credit_chunks(group_id) do
    rows(
      """
      SELECT credit_lot_id, amount_cents
        FROM credit_allocations
       WHERE group_record_id = ? ORDER BY id
      """,
      [group_id]
    )
    |> Enum.map(fn [lot_id, amount] -> %{lot_id: lot_id, amount: amount} end)
  end

  defp take_credit(chunks, amount, payment) do
    do_take_credit(chunks, amount, payment, [])
  end

  defp do_take_credit(chunks, 0, _payment, items), do: {Enum.reverse(items), chunks}
  defp do_take_credit([], _amount, _payment, items), do: {Enum.reverse(items), []}

  defp do_take_credit([chunk | chunks], amount, payment, items) do
    taken = min(chunk.amount, amount)
    item = %{type: "credit", amount: taken, payment: payment, lot_id: chunk.lot_id}

    remaining_chunks =
      if chunk.amount > taken,
        do: [%{chunk | amount: chunk.amount - taken} | chunks],
        else: chunks

    do_take_credit(remaining_chunks, amount - taken, payment, [item | items])
  end

  defp allocate_to_rooms(group_id, items) do
    rooms =
      rows(
        "SELECT id, deposit_due_cents FROM rooms WHERE group_record_id = ? ORDER BY position",
        [
          group_id
        ]
      )

    {_rooms, _order} =
      Enum.reduce(items, {rooms, 1}, fn item, {room_queue, order} ->
        allocate_item(item, room_queue, order)
      end)
  end

  defp allocate_item(%{amount: 0}, rooms, order), do: {rooms, order}

  defp allocate_item(item, rooms, order) do
    {updated_rooms, final_order, remaining} =
      Enum.reduce(rooms, {[], order, item.amount}, fn [room_id, capacity], {acc, next, left} ->
        taken = min(capacity, left)

        if taken > 0 do
          query!(
            """
            INSERT INTO room_allocations
              (room_id, credit_lot_id, funding_type, amount_cents, payment_operation_id,
               allocation_order, inserted_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
            """,
            [room_id, Map.get(item, :lot_id), item.type, taken, item.payment, next]
          )
        end

        {[[room_id, capacity - taken] | acc], next + if(taken > 0, do: 1, else: 0), left - taken}
      end)

    if remaining > 0, do: raise("legacy funding exceeds room deposit requirements")
    {Enum.reverse(updated_rooms), final_order}
  end

  defp backfill_settled_payment_dispositions do
    groups =
      rows("""
      SELECT id, cash_paid_cents, cash_refunded_cents, cash_retained_cents,
             cash_converted_to_credit_cents
        FROM groups WHERE status = 'cancelled'
      """)

    Enum.each(groups, fn [group_id, cash_paid, refunded, retained, converted] ->
      payments =
        rows(
          "SELECT id, recorded_cents FROM cash_payments WHERE group_record_id = ? ORDER BY id",
          [group_id]
        )

      legacy = max(cash_paid - Enum.sum(Enum.map(payments, &Enum.at(&1, 1))), 0)
      {refunded, legacy} = consume_senior(refunded, legacy)
      {retained, legacy} = consume_senior(retained, legacy)
      {converted, _legacy} = consume_senior(converted, legacy)

      payments
      |> Enum.reduce({refunded, retained, converted}, fn [id, recorded], state ->
        {refund_left, retain_left, convert_left} = state
        refund = min(recorded, refund_left)
        retained_amount = min(recorded - refund, retain_left)
        converted_amount = min(recorded - refund - retained_amount, convert_left)

        query!(
          """
          UPDATE cash_payments
             SET refunded_cents = ?, retained_cents = ?, converted_to_credit_cents = ?
           WHERE id = ?
          """,
          [refund, retained_amount, converted_amount, id]
        )

        {refund_left - refund, retain_left - retained_amount, convert_left - converted_amount}
      end)
    end)
  end

  defp backfill_credit_entitlements do
    lots =
      rows("""
      SELECT l.id, g.id, g.cash_converted_to_credit_cents
        FROM credit_lots l
        JOIN partner_operations po ON po.operation_id = l.source_operation_id
        JOIN groups g ON g.group_id = json_extract(po.result, '$.group_id')
       WHERE g.cash_converted_to_credit_cents > 0
       ORDER BY l.id
      """)

    Enum.each(lots, fn [lot_id, group_id, converted] ->
      payments =
        rows(
          """
          SELECT operation_id, converted_to_credit_cents
            FROM cash_payments
           WHERE group_record_id = ? AND converted_to_credit_cents > 0 ORDER BY id
          """,
          [group_id]
        )

      legacy = max(converted - Enum.sum(Enum.map(payments, &Enum.at(&1, 1))), 0)

      {_running, _previous_bonus} =
        Enum.reduce(payments, {legacy, bonus_value(legacy)}, fn [operation_id, principal],
                                                                {running, previous_value} ->
          new_running = running + principal
          new_value = bonus_value(new_running)
          entitlement = new_value - previous_value

          query!(
            """
            INSERT INTO credit_entitlements
              (credit_lot_id, payment_operation_id, issued_cents, revoked_cents,
               inserted_at, updated_at)
            VALUES (?, ?, ?, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
            """,
            [lot_id, operation_id, entitlement]
          )

          {new_running, new_value}
        end)
    end)
  end

  defp optional_item(_type, 0, _payment), do: []
  defp optional_item(type, amount, payment), do: [%{type: type, amount: amount, payment: payment}]

  defp consume_senior(amount, senior),
    do: {amount - min(amount, senior), senior - min(amount, senior)}

  defp sum_amounts(items), do: Enum.sum(Enum.map(items, & &1.amount))
  defp bonus_value(principal), do: principal + div(principal * 10 + 50, 100)
  defp rows(sql, params \\ []), do: query!(sql, params).rows
  defp query!(sql, params), do: repo().query!(sql, params)
end
