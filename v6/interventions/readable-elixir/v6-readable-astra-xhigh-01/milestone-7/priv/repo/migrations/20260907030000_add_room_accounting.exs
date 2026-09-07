defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
    end

    alter table(:credit_allocations) do
      add :room_id, references(:rooms)
    end

    create index(:credit_allocations, [:room_id, :status])

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    # Each partial cancellation may issue its own lot from the same group.
    drop unique_index(:credit_lots, [:source_group_id])
    create index(:credit_lots, [:source_group_id])

    create table(:cash_allocations) do
      add :group_id, references(:groups, column: :group_id, type: :string), null: false
      add :room_id, references(:rooms)
      add :payment_operation_id, :string
      add :credit_lot_id, references(:credit_lots)
      add :amount_cents, :integer, null: false
      add :disposition, :string, null: false, default: "held"
    end

    create index(:cash_allocations, [:payment_operation_id, :disposition])
    create index(:cash_allocations, [:group_id])
    create index(:cash_allocations, [:room_id, :disposition])

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots), null: false
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
    end

    create index(:credit_entitlements, [:payment_operation_id])
    create unique_index(:credit_entitlements, [:credit_lot_id, :payment_operation_id])
    flush()

    # Keep the backfill self-contained: future schema/context changes must not
    # change how this release upgrades old databases. No operations are replayed.
    groups =
      rows(
        "SELECT group_id, status, cash_paid_cents, arrival_on, departure_on, rate_plan FROM groups"
      )

    for [group_id, status, cash, arrival, departure, plan] <- groups do
      records = funding_records(group_id)

      if status == "active" do
        nights = Date.diff(Date.from_iso8601!(departure), Date.from_iso8601!(arrival))
        allocate_active_group(group_id, cash, nights, plan, records)
      else
        import_settled_cash(group_id, records)
        repo().query!("UPDATE rooms SET status = 'cancelled' WHERE group_id = ?", [group_id])
        repo().query!("UPDATE groups SET lodging_total_cents = 0 WHERE group_id = ?", [group_id])
      end
    end
  end

  def down do
    # The previous schema cannot represent partial cancellation or corrections.
    if rows("""
       SELECT id FROM operation_records
       WHERE operation_type IN ('cancel_rooms', 'reduce_cash_payment', 'charge_back_payment')
         AND json_extract(result, '$.status') = 'applied' LIMIT 1
       """) != [] do
      raise Ecto.MigrationError,
        message:
          "cannot downgrade room accounting after room cancellations or payment corrections"
    end

    # Recombine room portions into the previous release's group allocations.
    execute """
    UPDATE credit_allocations AS original
    SET amount_cents = (SELECT SUM(portion.amount_cents) FROM credit_allocations AS portion
      WHERE portion.group_id = original.group_id AND portion.operation_id = original.operation_id
        AND portion.credit_lot_id = original.credit_lot_id AND portion.status = original.status)
    WHERE original.id IN (SELECT MIN(id) FROM credit_allocations
      GROUP BY group_id, operation_id, credit_lot_id, status)
    """

    execute """
    DELETE FROM credit_allocations WHERE id NOT IN (SELECT MIN(id) FROM credit_allocations
      GROUP BY group_id, operation_id, credit_lot_id, status)
    """

    execute """
    UPDATE groups SET lodging_total_cents = (SELECT SUM(nightly_rate_cents) FROM rooms
      WHERE rooms.group_id = groups.group_id) * CAST(julianday(departure_on) - julianday(arrival_on) AS INTEGER)
    """

    drop table(:credit_entitlements)
    drop table(:cash_allocations)
    drop index(:credit_allocations, [:room_id, :status])
    alter table(:credit_allocations), do: remove(:room_id)
    alter table(:rooms), do: remove(:status)
    alter table(:credit_lots), do: remove(:unrecovered_clawback_cents)
    drop index(:credit_lots, [:source_group_id])
    create unique_index(:credit_lots, [:source_group_id])
  end

  defp funding_records(group_id) do
    rows(
      """
      SELECT operation_id, operation_type, result FROM operation_records
      WHERE operation_type IN ('record_cash_payment', 'apply_hotel_credit')
        AND json_extract(result, '$.status') = 'applied'
        AND json_extract(result, '$.group_id') = ?
      ORDER BY id
      """,
      [group_id]
    )
    |> Enum.map(fn [id, type, result] ->
      %{id: id, type: type, amount: Jason.decode!(result)["amount_cents"]}
    end)
  end

  defp allocate_active_group(group_id, cash, nights, plan, records) do
    capacities =
      rows("SELECT id, nightly_rate_cents FROM rooms WHERE group_id = ? ORDER BY position", [
        group_id
      ])
      |> Enum.map(fn [id, rate] ->
        lodging = rate * nights
        due = if plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging
        {id, due}
      end)

    credit =
      rows(
        """
        SELECT id, operation_id, amount_cents FROM credit_allocations
        WHERE group_id = ? AND status = 'applied' ORDER BY id
        """,
        [group_id]
      )
      |> Enum.map(fn [id, operation_id, amount] ->
        %{kind: :credit, id: id, operation_id: operation_id, amount: amount}
      end)

    recorded_cash =
      records
      |> Enum.filter(&(&1.type == "record_cash_payment"))
      |> Enum.map(& &1.amount)
      |> Enum.sum()

    recorded_credit_ids =
      records |> Enum.filter(&(&1.type == "apply_hotel_credit")) |> MapSet.new(& &1.id)

    legacy_credit = Enum.reject(credit, &MapSet.member?(recorded_credit_ids, &1.operation_id))
    senior = [%{kind: :cash, id: nil, amount: cash - recorded_cash} | legacy_credit]

    recorded =
      Enum.flat_map(records, fn record ->
        case record.type do
          "record_cash_payment" -> [%{kind: :cash, id: record.id, amount: record.amount}]
          "apply_hotel_credit" -> Enum.filter(credit, &(&1.operation_id == record.id))
        end
      end)

    Enum.reduce(senior ++ recorded, capacities, fn funding, capacities ->
      {capacities, portions} = fill(capacities, funding.amount)

      case funding.kind do
        :cash ->
          for {room_id, amount} <- portions,
              do: insert_cash(group_id, room_id, funding.id, amount, "held", nil)

        :credit ->
          assign_credit(funding.id, portions)
      end

      capacities
    end)
  end

  defp fill(capacities, amount) do
    {capacities, {remaining, portions}} =
      Enum.map_reduce(capacities, {amount, []}, fn {id, capacity}, {remaining, portions} ->
        allocated = min(capacity, remaining)
        portions = if allocated > 0, do: [{id, allocated} | portions], else: portions
        {{id, capacity - allocated}, {remaining - allocated, portions}}
      end)

    0 = remaining
    {capacities, Enum.reverse(portions)}
  end

  defp assign_credit(_id, []), do: :ok

  defp assign_credit(id, [{room_id, amount} | rest]) do
    for {next_room, next_amount} <- rest do
      repo().query!(
        """
        INSERT INTO credit_allocations (group_id, credit_lot_id, operation_id, amount_cents,
          status, inserted_at, updated_at, room_id)
        SELECT group_id, credit_lot_id, operation_id, ?, status, inserted_at, updated_at, ?
        FROM credit_allocations WHERE id = ?
        """,
        [next_amount, next_room, id]
      )
    end

    repo().query!("UPDATE credit_allocations SET room_id = ?, amount_cents = ? WHERE id = ?", [
      room_id,
      amount,
      id
    ])
  end

  defp import_settled_cash(group_id, records) do
    # Before room cancellation existed, all cash in a cancelled group had a
    # single settlement. Reconstruct attribution without altering that history.
    cash =
      rows("SELECT amount_cents FROM cash_entries WHERE group_id = ? AND kind = 'payment'", [
        group_id
      ])
      |> List.flatten()
      |> Enum.sum()

    payments = Enum.filter(records, &(&1.type == "record_cash_payment"))
    legacy = cash - Enum.sum(Enum.map(payments, & &1.amount))
    payments = [%{id: nil, amount: legacy} | payments] |> Enum.filter(&(&1.amount > 0))

    settlement =
      rows(
        "SELECT kind FROM cash_entries WHERE group_id = ? AND kind != 'payment' ORDER BY id LIMIT 1",
        [group_id]
      )

    disposition =
      case settlement do
        [["refund"]] -> "refunded"
        [["retention"]] -> "retained"
        [["credit_conversion"]] -> "converted_to_credit"
        [] when cash == 0 -> "refunded"
      end

    lot_id =
      case rows("SELECT id FROM credit_lots WHERE source_group_id = ?", [group_id]) do
        [[id]] -> id
        [] -> nil
      end

    Enum.reduce(payments, 0, fn payment, preceding ->
      insert_cash(group_id, nil, payment.id, payment.amount, disposition, lot_id)
      running = preceding + payment.amount

      if disposition == "converted_to_credit" do
        entitlement = bonus_value(running) - bonus_value(preceding)

        repo().query!(
          "INSERT INTO credit_entitlements (credit_lot_id, payment_operation_id, amount_cents) VALUES (?, ?, ?)",
          [lot_id, payment.id, entitlement]
        )
      end

      running
    end)
  end

  defp bonus_value(cash), do: cash + div(cash + 5, 10)

  defp insert_cash(group_id, room_id, payment_id, amount, disposition, lot_id) do
    repo().query!(
      """
      INSERT INTO cash_allocations (group_id, room_id, payment_operation_id, amount_cents, disposition, credit_lot_id)
      VALUES (?, ?, ?, ?, ?, ?)
      """,
      [group_id, room_id, payment_id, amount, disposition, lot_id]
    )
  end

  defp rows(sql, params \\ []), do: repo().query!(sql, params).rows
end
