defmodule GroupStay.Repo.Migrations.RoomAccountingAndPaymentReductions do
  use Ecto.Migration

  @moduledoc """
  Product request 04: room-level accounting and payment reductions.

  Rooms become individually active or cancelled and carry their own deposit
  requirement. Funding — cash payments and hotel credit — is represented by
  room allocations that record which room each cent funds, which durable
  operation supplied it, and its current disposition (held, refunded,
  retained, converted, reduced, charged back; restored or consumed for
  credit).

  Funding that predates durable operation records is brought forward as one
  unattributed senior block per group: aggregate cash first, then its
  hotel-credit lots in original consumption order. Funding represented by a
  durable operation record follows afterwards, in durable-record commit
  order. Existing credit lots gain the unrecovered-clawback bookkeeping and
  the per-payment entitlements needed by chargebacks.

  Ecto's migration DSL queues DDL and only executes it after the migration
  callback returns, while plain queries run inline. Because the data
  backfill must observe the new schema, this migration issues its DDL as
  explicit SQL, in execution order.
  """

  @now "2026-08-26 00:00:00"

  def up do
    sql!("ALTER TABLE \"rooms\" ADD COLUMN \"status\" TEXT NOT NULL DEFAULT 'active'")
    sql!("ALTER TABLE \"rooms\" ADD COLUMN \"deposit_due_cents\" INTEGER")

    # Each room's lodging is nights * nightly rate; the deposit is the full
    # lodging for advance purchase and 20% (half-up) for flexible.
    sql!("""
    UPDATE "rooms" SET "deposit_due_cents" = (
      SELECT CASE
        WHEN g.rate_plan = 'advance_purchase' THEN
          CAST(julianday(g.departure_on) - julianday(g.arrival_on) AS INTEGER) * rooms.nightly_rate_cents
        ELSE
          (CAST(julianday(g.departure_on) - julianday(g.arrival_on) AS INTEGER) * rooms.nightly_rate_cents * 20 + 50) / 100
      END
      FROM "groups" g WHERE g.id = rooms.group_id
    )
    """)

    # Groups cancelled before this release have no active rooms left and no
    # deposit still due.
    sql!(
      "UPDATE \"rooms\" SET \"status\" = 'cancelled' WHERE group_id IN (SELECT id FROM \"groups\" WHERE status = 'cancelled')"
    )

    sql!(
      "UPDATE \"groups\" SET \"lodging_total_cents\" = 0, \"deposit_due_cents\" = 0 WHERE status = 'cancelled'"
    )

    sql!("ALTER TABLE \"payments\" ADD COLUMN \"operation_id\" TEXT")
    sql!("CREATE UNIQUE INDEX \"payments_operation_id_index\" ON \"payments\" (\"operation_id\")")

    # Credit applications gain a temporary operation_id so the backfill can
    # tell durable credit from credit predating durable operation records.
    # The table itself is folded into room allocations below.
    sql!("ALTER TABLE \"credit_applications\" ADD COLUMN \"operation_id\" TEXT")

    sql!(
      "ALTER TABLE \"credit_lots\" ADD COLUMN \"unrecovered_clawback_cents\" INTEGER DEFAULT 0 NOT NULL"
    )

    sql!("""
    CREATE TABLE "room_allocations" ("id" INTEGER PRIMARY KEY AUTOINCREMENT,
      "group_id" INTEGER NOT NULL CONSTRAINT "room_allocations_group_id_fkey" REFERENCES "groups"("id") ON DELETE CASCADE,
      "room_id" INTEGER NOT NULL CONSTRAINT "room_allocations_room_id_fkey" REFERENCES "rooms"("id") ON DELETE CASCADE,
      "source" TEXT NOT NULL,
      "operation_id" TEXT,
      "lot_id" INTEGER CONSTRAINT "room_allocations_lot_id_fkey" REFERENCES "credit_lots"("id") ON DELETE CASCADE,
      "amount_cents" INTEGER NOT NULL,
      "state" TEXT NOT NULL,
      "inserted_at" TEXT NOT NULL,
      "updated_at" TEXT NOT NULL)
    """)

    sql!(
      "CREATE INDEX \"room_allocations_group_id_index\" ON \"room_allocations\" (\"group_id\")"
    )

    sql!("CREATE INDEX \"room_allocations_room_id_index\" ON \"room_allocations\" (\"room_id\")")

    sql!(
      "CREATE INDEX \"room_allocations_operation_id_index\" ON \"room_allocations\" (\"operation_id\")"
    )

    sql!("CREATE INDEX \"room_allocations_lot_id_index\" ON \"room_allocations\" (\"lot_id\")")
    sql!("CREATE INDEX \"room_allocations_state_index\" ON \"room_allocations\" (\"state\")")

    sql!("""
    CREATE TABLE "credit_entitlements" ("id" INTEGER PRIMARY KEY AUTOINCREMENT,
      "lot_id" INTEGER NOT NULL CONSTRAINT "credit_entitlements_lot_id_fkey" REFERENCES "credit_lots"("id") ON DELETE CASCADE,
      "payment_operation_id" TEXT NOT NULL,
      "entitlement_cents" INTEGER NOT NULL,
      "inserted_at" TEXT NOT NULL,
      "updated_at" TEXT NOT NULL)
    """)

    sql!(
      "CREATE INDEX \"credit_entitlements_lot_id_index\" ON \"credit_entitlements\" (\"lot_id\")"
    )

    sql!(
      "CREATE INDEX \"credit_entitlements_payment_operation_id_index\" ON \"credit_entitlements\" (\"payment_operation_id\")"
    )

    backfill_funding()
    backfill_entitlements()

    sql!("DROP TABLE \"credit_applications\"")
    sql!("DROP INDEX \"payments_state_index\"")
    sql!("ALTER TABLE \"payments\" DROP COLUMN \"state\"")
  end

  def down do
    sql!("ALTER TABLE \"payments\" ADD COLUMN \"state\" TEXT NOT NULL DEFAULT 'held'")

    # A payment's disposition becomes the state of its most recent
    # allocation; funding without allocations counts as held.
    sql!("""
    UPDATE "payments" SET "state" = COALESCE((
      SELECT a.state FROM "room_allocations" a
      WHERE a.operation_id = payments.operation_id AND a.source = 'cash'
      ORDER BY a.id DESC LIMIT 1
    ), 'held')
    """)

    sql!("""
    CREATE TABLE "credit_applications" ("id" INTEGER PRIMARY KEY AUTOINCREMENT,
      "group_id" INTEGER NOT NULL CONSTRAINT "credit_applications_group_id_fkey" REFERENCES "groups"("id") ON DELETE CASCADE,
      "lot_id" INTEGER NOT NULL CONSTRAINT "credit_applications_lot_id_fkey" REFERENCES "credit_lots"("id") ON DELETE CASCADE,
      "amount_cents" INTEGER NOT NULL,
      "state" TEXT DEFAULT 'applied' NOT NULL,
      "inserted_at" TEXT NOT NULL,
      "updated_at" TEXT NOT NULL)
    """)

    sql!(
      "CREATE INDEX \"credit_applications_group_id_index\" ON \"credit_applications\" (\"group_id\")"
    )

    sql!(
      "CREATE INDEX \"credit_applications_lot_id_index\" ON \"credit_applications\" (\"lot_id\")"
    )

    sql!(
      "CREATE INDEX \"credit_applications_state_index\" ON \"credit_applications\" (\"state\")"
    )

    sql!("DROP TABLE \"credit_entitlements\"")
    sql!("DROP TABLE \"room_allocations\"")

    sql!("DROP INDEX \"payments_operation_id_index\"")
    sql!("ALTER TABLE \"credit_lots\" DROP COLUMN \"unrecovered_clawback_cents\"")
    sql!("ALTER TABLE \"payments\" DROP COLUMN \"operation_id\"")

    sql!("""
    UPDATE "groups" SET
      "lodging_total_cents" = (
        SELECT COALESCE(SUM(CAST(julianday(groups.departure_on) - julianday(groups.arrival_on) AS INTEGER) * r.nightly_rate_cents), 0)
        FROM "rooms" r WHERE r.group_id = groups.id
      ),
      "deposit_due_cents" = (SELECT COALESCE(SUM(r.deposit_due_cents), 0) FROM "rooms" r WHERE r.group_id = groups.id)
    """)

    sql!("UPDATE \"rooms\" SET \"status\" = 'active'")
    sql!("ALTER TABLE \"rooms\" DROP COLUMN \"status\"")
    sql!("ALTER TABLE \"rooms\" DROP COLUMN \"deposit_due_cents\"")

    sql!("CREATE INDEX \"payments_state_index\" ON \"payments\" (\"state\")")
  end

  defp sql!(statement), do: repo().query!(statement)

  # -- funding attribution ------------------------------------------------------

  defp backfill_funding do
    groups = repo().query!("SELECT id, group_id FROM groups ORDER BY id").rows

    match_funding_to_operations(groups, "record_cash_payment", "payments")
    match_funding_to_operations(groups, "apply_hotel_credit", "credit_applications")

    Enum.each(groups, fn [group_pk, _group_id] -> build_group_allocations(group_pk) end)
  end

  # Pairs durable payment/credit operations with the funding rows they
  # created, claiming rows by group and amount in order. Unclaimed rows are
  # the funding from before durable operation records existed.
  defp match_funding_to_operations(groups, type, table) do
    ops = durable_funding_operations(type)

    Enum.each(groups, fn [group_pk, group_id] ->
      group_ops =
        Enum.filter(ops, fn {_pk, _op_id, op_group_id, _amount} -> op_group_id == group_id end)

      rows =
        repo().query!("SELECT id, amount_cents FROM #{table} WHERE group_id = ? ORDER BY id", [
          group_pk
        ]).rows

      {claims, _unclaimed} =
        Enum.reduce(group_ops, {[], rows}, fn {_op_pk, op_id, _gid, amount},
                                              {claimed, available} ->
          case Enum.find_index(available, fn [_row_pk, row_amount] -> row_amount == amount end) do
            nil ->
              {claimed, available}

            index ->
              {row, rest} = List.pop_at(available, index)
              {[{row, op_id} | claimed], rest}
          end
        end)

      Enum.each(claims, fn {[row_pk, _amount], op_id} ->
        repo().query!("UPDATE #{table} SET operation_id = ? WHERE id = ?", [op_id, row_pk])
      end)
    end)
  end

  defp durable_funding_operations(type) do
    rows =
      repo().query!(
        "SELECT id, operation_id, result FROM partner_operations WHERE type = ? ORDER BY id",
        [
          type
        ]
      ).rows

    Enum.flat_map(rows, fn [_pk, op_id, result] ->
      case Jason.decode(result) do
        {:ok, %{"status" => "applied", "group_id" => group_id, "amount_cents" => amount}}
        when is_integer(amount) ->
          [{nil, op_id, group_id, amount}]

        _ ->
          []
      end
    end)
  end

  # Builds each group's room allocations in funding order: the unattributed
  # senior block first (aggregate cash, then hotel-credit lots in original
  # consumption order), then funding with a durable operation record in
  # durable-record commit order.
  defp build_group_allocations(group_pk) do
    rooms =
      repo().query!(
        "SELECT id, deposit_due_cents FROM rooms WHERE group_id = ? ORDER BY position",
        [
          group_pk
        ]
      ).rows

    capacities = Enum.map(rooms, fn [_room_pk, due] -> due || 0 end)

    legacy_cash =
      repo().query!(
        "SELECT state, SUM(amount_cents) FROM payments WHERE group_id = ? AND operation_id IS NULL GROUP BY state ORDER BY state",
        [group_pk]
      ).rows

    legacy_credit =
      repo().query!(
        "SELECT lot_id, state, amount_cents FROM credit_applications WHERE group_id = ? AND operation_id IS NULL ORDER BY id",
        [group_pk]
      ).rows

    durable =
      repo().query!(
        """
        SELECT 'cash' AS source, p.operation_id AS operation_id, p.state AS state,
               p.amount_cents AS amount_cents, NULL AS lot_id,
               (SELECT MIN(o.id) FROM partner_operations o WHERE o.operation_id = p.operation_id) AS commit_order
        FROM payments p
        WHERE p.group_id = ?1 AND p.operation_id IS NOT NULL
        UNION ALL
        SELECT 'credit', a.operation_id, a.state, a.amount_cents, a.lot_id,
               (SELECT MIN(o.id) FROM partner_operations o WHERE o.operation_id = a.operation_id)
        FROM credit_applications a
        WHERE a.group_id = ?1 AND a.operation_id IS NOT NULL
        """,
        [group_pk]
      ).rows
      # Durable-record commit order, regardless of occurred_on.
      |> Enum.sort_by(fn [_source, _op_id, _state, _amount, _lot_pk, commit_order] ->
        commit_order
      end)

    events =
      Enum.map(legacy_cash, fn [state, total] -> {"cash", nil, state, total, nil} end) ++
        Enum.map(legacy_credit, fn [lot_pk, state, amount] ->
          {"credit", nil, allocation_state("credit", state), amount, lot_pk}
        end) ++
        Enum.map(durable, fn [source, op_id, state, amount, lot_pk, _commit_order] ->
          {source, op_id, allocation_state(source, state), amount, lot_pk}
        end)

    Enum.reduce(events, capacities, fn {source, op_id, state, amount, lot_pk}, capacities ->
      {takes, capacities} = fill(capacities, amount)

      Enum.each(Enum.zip(rooms, takes), fn {[room_pk, _due], take} ->
        if take > 0 do
          insert_allocation(group_pk, room_pk, source, op_id, lot_pk, take, state)
        end
      end)

      capacities
    end)

    :ok
  end

  # Fills room capacities in order, filling one room's deposit before moving
  # to the next. Any amount beyond the rooms' combined capacity (an anomaly
  # under the earlier releases' validation) lands on the last room so the
  # allocation total still equals the funding total.
  defp fill(capacities, amount) do
    {takes, leftover} =
      Enum.map_reduce(capacities, amount, fn capacity, remaining ->
        take = min(max(capacity, 0), remaining)
        {take, remaining - take}
      end)

    takes = bump_last(takes, leftover)
    {takes, Enum.zip_with(capacities, takes, fn capacity, take -> capacity - take end)}
  end

  defp bump_last([], _leftover), do: []

  defp bump_last(takes, leftover) when leftover <= 0, do: takes

  defp bump_last(takes, leftover) do
    List.update_at(takes, -1, &(&1 + leftover))
  end

  # A credit application that still funds its group becomes a held credit
  # allocation; settled applications keep their settlement state.
  defp allocation_state("credit", "applied"), do: "held"
  defp allocation_state(_source, state), do: state

  defp insert_allocation(group_pk, room_pk, source, op_id, lot_pk, amount, state) do
    repo().query!(
      """
      INSERT INTO room_allocations
        (group_id, room_id, source, operation_id, lot_id, amount_cents, state, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [group_pk, room_pk, source, op_id, lot_pk, amount, state, @now, @now]
    )
  end

  # -- credit entitlements --------------------------------------------------------

  # Reconstructs the per-payment entitlements of lots issued by earlier
  # releases: the payments a cancellation converted, in funding order, share
  # the lot by telescoped 10%-bonus value.
  defp backfill_entitlements do
    lots = repo().query!("SELECT id, source_operation_id FROM credit_lots ORDER BY id").rows

    Enum.each(lots, fn [lot_pk, source_operation_id] ->
      with %{rows: [[result]]} <-
             repo().query!("SELECT result FROM partner_operations WHERE operation_id = ?", [
               source_operation_id
             ]),
           {:ok, %{"status" => "applied", "group_id" => group_id}} <- Jason.decode(result),
           [[group_pk]] <-
             repo().query!("SELECT id FROM groups WHERE group_id = ?", [group_id]).rows do
        converted =
          repo().query!(
            """
            SELECT operation_id, amount_cents FROM payments
            WHERE group_id = ? AND state = 'converted'
            ORDER BY CASE WHEN operation_id IS NULL THEN 0 ELSE 1 END,
                     CASE WHEN operation_id IS NULL THEN id
                          ELSE (SELECT MIN(o.id) FROM partner_operations o WHERE o.operation_id = payments.operation_id) END
            """,
            [group_pk]
          ).rows

        {entitlements, _cumulative, _bonus} =
          Enum.reduce(converted, {[], 0, 0}, fn [op_id, amount],
                                                {acc, cumulative, previous_bonus} ->
            cumulative = cumulative + amount
            bonus_value = bonus_value(cumulative)
            acc = if op_id, do: [{op_id, bonus_value - previous_bonus} | acc], else: acc
            {acc, cumulative, bonus_value}
          end)

        Enum.each(entitlements, fn {op_id, entitlement} ->
          insert_entitlement(lot_pk, op_id, entitlement)
        end)

        repo().query!(
          "UPDATE room_allocations SET lot_id = ? WHERE group_id = ? AND source = 'cash' AND state = 'converted'",
          [lot_pk, group_pk]
        )
      end
    end)
  end

  defp insert_entitlement(lot_pk, payment_operation_id, entitlement) do
    repo().query!(
      """
      INSERT INTO credit_entitlements
        (lot_id, payment_operation_id, entitlement_cents, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?)
      """,
      [lot_pk, payment_operation_id, entitlement, @now, @now]
    )
  end

  defp bonus_value(cash_cents), do: cash_cents + div(cash_cents * 10 + 50, 100)
end
