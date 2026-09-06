defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentCorrections do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :status, :string, null: false, default: "active"
    end

    alter table(:hotel_credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:credit_allocations) do
      add :room_id, references(:rooms, on_delete: :delete_all)
    end

    create index(:credit_allocations, [:room_id, :hotel_credit_lot_id])

    create table(:cash_payment_sources) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :payment_operation_id, :string
      add :recorded_cents, :integer, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
    end

    create unique_index(:cash_payment_sources, [:payment_operation_id])
    create index(:cash_payment_sources, [:group_id])

    create table(:cash_room_allocations) do
      add :room_id, references(:rooms, on_delete: :delete_all), null: false

      add :cash_payment_source_id, references(:cash_payment_sources, on_delete: :restrict),
        null: false

      add :amount_cents, :integer, null: false
    end

    create index(:cash_room_allocations, [:room_id, :cash_payment_source_id])

    create table(:payment_credit_entitlements) do
      add :cash_payment_source_id, references(:cash_payment_sources, on_delete: :restrict),
        null: false

      add :hotel_credit_lot_id, references(:hotel_credit_lots, on_delete: :restrict), null: false
      add :credit_cents, :integer, null: false
    end

    create index(:payment_credit_entitlements, [:cash_payment_source_id])
    create index(:payment_credit_entitlements, [:hotel_credit_lot_id])

    # Run the schema changes before using raw SQL to carry existing balances into the new tables.
    flush()
    backfill_room_amounts()
    backfill_payment_sources()
    backfill_cancelled_payment_dispositions()
    backfill_credit_entitlements()
    flush()
    backfill_active_room_allocations()
  end

  def down do
    drop table(:payment_credit_entitlements)
    drop table(:cash_room_allocations)
    drop table(:cash_payment_sources)
    drop index(:credit_allocations, [:room_id, :hotel_credit_lot_id])

    alter table(:credit_allocations) do
      remove :room_id
    end

    alter table(:hotel_credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:rooms) do
      remove :status
      remove :deposit_due_cents
      remove :lodging_total_cents
    end
  end

  defp backfill_room_amounts do
    execute("""
    UPDATE rooms
    SET lodging_total_cents = nightly_rate_cents * (
          SELECT CAST(julianday(departure_on) - julianday(arrival_on) AS INTEGER)
          FROM groups WHERE groups.id = rooms.group_id
        ),
        deposit_due_cents = CASE
          WHEN (SELECT rate_plan FROM groups WHERE groups.id = rooms.group_id) = 'advance_purchase'
            THEN nightly_rate_cents * (
              SELECT CAST(julianday(departure_on) - julianday(arrival_on) AS INTEGER)
              FROM groups WHERE groups.id = rooms.group_id
            )
          ELSE (
            nightly_rate_cents * (
              SELECT CAST(julianday(departure_on) - julianday(arrival_on) AS INTEGER)
              FROM groups WHERE groups.id = rooms.group_id
            ) * 20 + 50
          ) / 100
        END,
        status = CASE
          WHEN (SELECT status FROM groups WHERE groups.id = rooms.group_id) = 'cancelled'
            THEN 'cancelled'
          ELSE 'active'
        END
    """)
  end

  defp backfill_payment_sources do
    # SQLite stores Ecto maps as JSON, so durable payment records can be carried forward without
    # depending on application schemas that may change in a later release.
    execute("""
    INSERT INTO cash_payment_sources (
      group_id, payment_operation_id, recorded_cents, refunded_cents, retained_cents,
      converted_to_credit_cents, reduced_cents, charged_back_cents
    )
    SELECT groups.id, partner_operations.operation_id,
      CAST(json_extract(partner_operations.result, '$.amount_cents') AS INTEGER),
      0, 0, 0, 0, 0
    FROM partner_operations
    JOIN groups ON groups.group_id = json_extract(partner_operations.result, '$.group_id')
    WHERE partner_operations.operation_type = 'record_cash_payment'
      AND json_extract(partner_operations.result, '$.status') = 'applied'
    """)

    execute("""
    INSERT INTO cash_payment_sources (
      group_id, payment_operation_id, recorded_cents, refunded_cents, retained_cents,
      converted_to_credit_cents, reduced_cents, charged_back_cents
    )
    SELECT groups.id, NULL,
      MAX(groups.cash_paid_cents - COALESCE((
        SELECT SUM(recorded_cents) FROM cash_payment_sources
        WHERE cash_payment_sources.group_id = groups.id
      ), 0), 0),
      0, 0, 0, 0, 0
    FROM groups
    WHERE groups.status = 'active'
      AND groups.cash_paid_cents > COALESCE((
        SELECT SUM(recorded_cents) FROM cash_payment_sources
        WHERE cash_payment_sources.group_id = groups.id
      ), 0)
    """)

    execute("""
    INSERT INTO cash_payment_sources (
      group_id, payment_operation_id, recorded_cents, refunded_cents, retained_cents,
      converted_to_credit_cents, reduced_cents, charged_back_cents
    )
    SELECT groups.id, NULL,
      MAX(
        groups.refunded_cents + groups.retained_cents + groups.cash_converted_to_credit_cents -
          COALESCE((
            SELECT SUM(recorded_cents) FROM cash_payment_sources
            WHERE cash_payment_sources.group_id = groups.id
          ), 0),
        0
      ),
      0, 0, 0, 0, 0
    FROM groups
    WHERE groups.status = 'cancelled'
      AND groups.refunded_cents + groups.retained_cents + groups.cash_converted_to_credit_cents >
        COALESCE((
          SELECT SUM(recorded_cents) FROM cash_payment_sources
          WHERE cash_payment_sources.group_id = groups.id
        ), 0)
    """)
  end

  defp backfill_cancelled_payment_dispositions do
    execute("""
    UPDATE cash_payment_sources
    SET refunded_cents = CASE
          WHEN (SELECT refunded_cents FROM groups WHERE groups.id = cash_payment_sources.group_id) > 0
            THEN recorded_cents
          ELSE 0
        END,
        retained_cents = CASE
          WHEN (SELECT retained_cents FROM groups WHERE groups.id = cash_payment_sources.group_id) > 0
            THEN recorded_cents
          ELSE 0
        END,
        converted_to_credit_cents = CASE
          WHEN (SELECT cash_converted_to_credit_cents FROM groups WHERE groups.id = cash_payment_sources.group_id) > 0
            THEN recorded_cents
          ELSE 0
        END
    WHERE (SELECT status FROM groups WHERE groups.id = cash_payment_sources.group_id) = 'cancelled'
    """)
  end

  defp backfill_credit_entitlements do
    # A pre-room-accounting cancellation created one lot for the whole group. Recreate the
    # per-payment bonus entitlement in the same legacy-then-durable funding order.
    execute("""
    INSERT INTO payment_credit_entitlements (
      cash_payment_source_id, hotel_credit_lot_id, credit_cents
    )
    WITH ordered_sources AS (
      SELECT sources.id AS source_id,
        lots.id AS lot_id,
        sources.recorded_cents,
        SUM(sources.recorded_cents) OVER (
          PARTITION BY lots.id
          ORDER BY CASE WHEN sources.payment_operation_id IS NULL THEN 0 ELSE 1 END,
                   operations.id
          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS running_cents
      FROM cash_payment_sources AS sources
      JOIN groups ON groups.id = sources.group_id
      JOIN partner_operations AS cancellations
        ON cancellations.operation_id = json_extract(cancellations.result, '$.operation_id')
        AND json_extract(cancellations.result, '$.group_id') = groups.group_id
      JOIN hotel_credit_lots AS lots
        ON lots.source_operation_id = cancellations.operation_id
      LEFT JOIN partner_operations AS operations
        ON operations.operation_id = sources.payment_operation_id
      WHERE sources.converted_to_credit_cents > 0
        AND cancellations.operation_type = 'cancel_group'
        AND json_extract(cancellations.result, '$.status') = 'applied'
    )
    SELECT source_id,
      lot_id,
      running_cents + ((running_cents * 10 + 50) / 100) -
        (running_cents - recorded_cents) -
        (((running_cents - recorded_cents) * 10 + 50) / 100)
    FROM ordered_sources
    """)
  end

  defp backfill_active_room_allocations do
    repo = repo()

    active_groups =
      repo.query!("SELECT id FROM groups WHERE status = 'active'").rows

    Enum.each(active_groups, fn [group_id] ->
      rooms =
        repo.query!(
          "SELECT id, deposit_due_cents FROM rooms WHERE group_id = ? AND status = 'active' ORDER BY position",
          [group_id]
        ).rows

      sources =
        repo.query!(
          """
          SELECT payment_operation_id, id, recorded_cents
          FROM cash_payment_sources
          WHERE group_id = ?
          """,
          [group_id]
        ).rows

      sources_by_operation =
        Map.new(sources, fn [payment_operation_id, source_id, amount] ->
          {payment_operation_id, {source_id, amount}}
        end)

      credit_chunks =
        repo.query!(
          "SELECT hotel_credit_lot_id, amount_cents FROM credit_allocations WHERE group_id = ? ORDER BY id",
          [group_id]
        ).rows
        |> Enum.map(fn [lot_id, amount] -> {lot_id, amount} end)

      funding_operations =
        repo.query!(
          """
          SELECT operation_type, operation_id, CAST(json_extract(result, '$.amount_cents') AS INTEGER)
          FROM partner_operations
          WHERE json_extract(result, '$.group_id') = (
              SELECT group_id FROM groups WHERE id = ?
            )
            AND json_extract(result, '$.status') = 'applied'
            AND operation_type IN ('record_cash_payment', 'apply_hotel_credit')
          ORDER BY id
          """,
          [group_id]
        ).rows

      durable_credit_cents =
        funding_operations
        |> Enum.filter(fn [operation_type, _operation_id, _amount] ->
          operation_type == "apply_hotel_credit"
        end)
        |> Enum.sum_by(fn [_operation_type, _operation_id, amount] -> amount end)

      legacy_credit_cents =
        Enum.sum_by(credit_chunks, fn {_lot_id, amount} -> amount end) - durable_credit_cents

      if legacy_credit_cents < 0 do
        raise "durable credit exceeds the group's recorded credit"
      end

      repo.query!("DELETE FROM credit_allocations WHERE group_id = ?", [group_id])

      balances = Map.new(rooms, fn [id, due] -> {id, due} end)

      balances =
        case Map.get(sources_by_operation, nil) do
          nil -> balances
          {source_id, amount} -> allocate_cash(repo, rooms, balances, source_id, amount)
        end

      {legacy_credit, credit_chunks} = take_credit_chunks(credit_chunks, legacy_credit_cents)
      balances = allocate_credit(repo, group_id, rooms, balances, legacy_credit)

      {balances, credit_chunks} =
        Enum.reduce(funding_operations, {balances, credit_chunks}, fn
          ["record_cash_payment", operation_id, _amount], {balances, chunks} ->
            {source_id, recorded_cents} = Map.fetch!(sources_by_operation, operation_id)
            {allocate_cash(repo, rooms, balances, source_id, recorded_cents), chunks}

          ["apply_hotel_credit", _operation_id, amount], {balances, chunks} ->
            {credit, chunks} = take_credit_chunks(chunks, amount)
            {allocate_credit(repo, group_id, rooms, balances, credit), chunks}
        end)

      if Enum.any?(credit_chunks, fn {_lot_id, amount} -> amount > 0 end) do
        raise "unclassified historical hotel credit remains"
      end

      if Enum.any?(balances, fn {_room_id, capacity} -> capacity < 0 end) do
        raise "existing funding exceeds room deposits"
      end
    end)
  end

  defp allocate_cash(repo, rooms, balances, source_id, amount) do
    {allocations, balances} = take_room_capacity(balances, rooms, amount)

    Enum.each(allocations, fn {room_id, cents} ->
      repo.query!(
        "INSERT INTO cash_room_allocations (room_id, cash_payment_source_id, amount_cents) VALUES (?, ?, ?)",
        [room_id, source_id, cents]
      )
    end)

    balances
  end

  defp allocate_credit(repo, group_id, rooms, balances, chunks) do
    Enum.reduce(chunks, balances, fn {lot_id, amount}, balances ->
      {allocations, balances} = take_room_capacity(balances, rooms, amount)

      Enum.each(allocations, fn {room_id, cents} ->
        repo.query!(
          "INSERT INTO credit_allocations (group_id, room_id, hotel_credit_lot_id, amount_cents) VALUES (?, ?, ?, ?)",
          [group_id, room_id, lot_id, cents]
        )
      end)

      balances
    end)
  end

  defp take_credit_chunks(chunks, amount), do: take_credit_chunks(chunks, amount, [])

  defp take_credit_chunks(chunks, 0, taken), do: {Enum.reverse(taken), chunks}

  defp take_credit_chunks([], _amount, _taken) do
    raise "existing hotel credit is smaller than the durable operation record"
  end

  defp take_credit_chunks([{lot_id, available} | chunks], amount, taken) do
    used = min(available, amount)
    chunks = if available == used, do: chunks, else: [{lot_id, available - used} | chunks]
    take_credit_chunks(chunks, amount - used, [{lot_id, used} | taken])
  end

  defp take_room_capacity(balances, rooms, amount) do
    Enum.reduce_while(rooms, {[], amount, balances}, fn [room_id, _due],
                                                        {parts, remaining, balances} ->
      capacity = Map.fetch!(balances, room_id)
      cents = min(capacity, remaining)
      balances = Map.put(balances, room_id, capacity - cents)
      parts = if cents > 0, do: parts ++ [{room_id, cents}], else: parts

      if remaining == cents do
        {:halt, {parts, 0, balances}}
      else
        {:cont, {parts, remaining - cents, balances}}
      end
    end)
    |> then(fn {parts, remaining, balances} ->
      if remaining == 0,
        do: {parts, balances},
        else: raise("existing funding exceeds room deposits")
    end)
  end
end
