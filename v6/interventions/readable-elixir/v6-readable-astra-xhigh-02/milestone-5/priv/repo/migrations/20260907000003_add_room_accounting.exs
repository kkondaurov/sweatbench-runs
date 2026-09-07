defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    drop unique_index(:credit_lots, [:source_group_id])
    create index(:credit_lots, [:source_group_id])

    create table(:cash_payments) do
      # Nullable for one senior balance per group predating durable operations.
      add :payment_operation_id, :string
      add :group_id, references(:groups, column: :group_id, type: :string), null: false
      add :recorded_cents, :integer, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
    end

    create unique_index(:cash_payments, [:payment_operation_id])
    create index(:cash_payments, [:group_id])

    create table(:room_allocations) do
      add :room_id, references(:rooms), null: false
      add :cash_payment_id, references(:cash_payments)
      add :credit_lot_id, references(:credit_lots)
      add :amount_cents, :integer, null: false
    end

    create index(:room_allocations, [:room_id])
    create index(:room_allocations, [:cash_payment_id])
    create index(:room_allocations, [:credit_lot_id])

    create table(:credit_entitlements) do
      add :cash_payment_id, references(:cash_payments), null: false
      add :credit_lot_id, references(:credit_lots), null: false
      add :amount_cents, :integer, null: false
    end

    create unique_index(:credit_entitlements, [:cash_payment_id, :credit_lot_id])
    create index(:credit_entitlements, [:credit_lot_id])
    flush()

    # Keep this backfill independent of application schemas and current business
    # code so a future release can still migrate a database from these releases.
    operations =
      rows("SELECT * FROM operations ORDER BY id")
      |> Enum.map(&Map.put(&1, "result", Jason.decode!(&1["result"])))
      |> Enum.filter(&(&1["result"]["status"] == "applied"))

    for group <- rows("SELECT * FROM groups ORDER BY group_id") do
      backfill_group(group, operations)
    end
  end

  def down do
    # Room settlements and payment corrections have no representation in the
    # old schema. Roll back only before accepting operations on the new release.
    restore_legacy_totals!()
    drop table(:credit_entitlements)
    drop table(:room_allocations)
    drop table(:cash_payments)
    drop index(:credit_lots, [:source_group_id])
    create unique_index(:credit_lots, [:source_group_id])

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:rooms) do
      remove :deposit_due_cents
      remove :lodging_total_cents
      remove :status
    end
  end

  defp restore_legacy_totals! do
    corrections =
      rows("""
      SELECT result FROM operations
      WHERE type IN ('cancel_rooms', 'reduce_cash_payment', 'charge_back_payment')
      """)

    if Enum.any?(corrections, &(Jason.decode!(&1["result"])["status"] == "applied")) do
      raise Ecto.MigrationError,
        message:
          "room settlements and payment corrections require a forward migration; downgrade would lose accounting history"
    end

    for group <- rows("SELECT * FROM groups WHERE status = 'cancelled'") do
      lodging =
        rows("SELECT lodging_total_cents FROM rooms WHERE group_id = ?", [group["group_id"]])
        |> Enum.map(& &1["lodging_total_cents"])
        |> Enum.sum()

      credit =
        rows("SELECT amount_cents FROM credit_applications WHERE group_id = ?", [
          group["group_id"]
        ])
        |> Enum.map(& &1["amount_cents"])
        |> Enum.sum()

      cash =
        group["refunded_cents"] + group["retained_cents"] +
          group["cash_converted_to_credit_cents"]

      repo().query!(
        """
        UPDATE groups SET lodging_total_cents = ?, deposit_paid_cents = ?, credit_paid_cents = ?
        WHERE group_id = ?
        """,
        [lodging, cash + credit, credit, group["group_id"]]
      )
    end
  end

  defp backfill_group(group, operations) do
    funding =
      Enum.filter(operations, fn operation ->
        operation["result"]["group_id"] == group["group_id"] and
          operation["type"] in ["record_cash_payment", "apply_hotel_credit"]
      end)

    rooms = price_rooms(group)
    cash = group["deposit_paid_cents"] - group["credit_paid_cents"]
    legacy_cash = cash - recorded_amount(funding, "record_cash_payment")
    legacy_credit = group["credit_paid_cents"] - recorded_amount(funding, "apply_hotel_credit")

    lots =
      rows("SELECT * FROM credit_applications WHERE group_id = ? ORDER BY id", [group["group_id"]])
      |> Enum.map(&{&1["credit_lot_id"], &1["amount_cents"]})

    # The unattributed block is senior to every recorded funding operation:
    # aggregate cash first, followed by lots in original consumption order.
    rooms = add_cash(group, nil, legacy_cash, rooms)
    {rooms, lots} = add_credit(group, legacy_credit, rooms, lots)

    {rooms, _lots} =
      Enum.reduce(funding, {rooms, lots}, fn operation, {rooms, lots} ->
        amount = operation["result"]["amount_cents"]

        case operation["type"] do
          "record_cash_payment" ->
            {add_cash(group, operation["operation_id"], amount, rooms), lots}

          "apply_hotel_credit" ->
            add_credit(group, amount, rooms, lots)
        end
      end)

    if group["status"] == "cancelled" do
      backfill_entitlements(group)

      repo().query!(
        """
        UPDATE groups SET lodging_total_cents = 0, deposit_due_cents = 0,
          deposit_paid_cents = 0, credit_paid_cents = 0 WHERE group_id = ?
        """,
        [group["group_id"]]
      )
    else
      # Allocating must not change any aggregate funding or liability balance.
      true =
        Enum.sum(Enum.map(rooms, &elem(&1, 1))) ==
          group["deposit_due_cents"] - group["deposit_paid_cents"]
    end
  end

  defp price_rooms(group) do
    nights =
      Date.diff(
        Date.from_iso8601!(group["departure_on"]),
        Date.from_iso8601!(group["arrival_on"])
      )

    rows("SELECT * FROM rooms WHERE group_id = ? ORDER BY position", [group["group_id"]])
    |> Enum.map(fn room ->
      lodging = nights * room["nightly_rate_cents"]

      due =
        if group["rate_plan"] == "advance_purchase",
          do: lodging,
          else: div(lodging * 20 + 50, 100)

      repo().query!(
        "UPDATE rooms SET status = ?, lodging_total_cents = ?, deposit_due_cents = ? WHERE id = ?",
        [group["status"], lodging, due, room["id"]]
      )

      {room["id"], due}
    end)
  end

  defp recorded_amount(operations, type) do
    operations
    |> Enum.filter(&(&1["type"] == type))
    |> Enum.map(& &1["result"]["amount_cents"])
    |> Enum.sum()
  end

  defp add_cash(_group, _operation_id, 0, rooms), do: rooms

  defp add_cash(group, operation_id, amount, rooms) do
    true = amount > 0
    settled? = group["status"] == "cancelled"
    refunded = if settled? and group["refunded_cents"] > 0, do: amount, else: 0
    retained = if settled? and group["retained_cents"] > 0, do: amount, else: 0
    converted = if settled? and group["cash_converted_to_credit_cents"] > 0, do: amount, else: 0

    [[id]] =
      repo().query!(
        """
        INSERT INTO cash_payments (payment_operation_id, group_id, recorded_cents,
          refunded_cents, retained_cents, converted_to_credit_cents)
        VALUES (?, ?, ?, ?, ?, ?) RETURNING id
        """,
        [operation_id, group["group_id"], amount, refunded, retained, converted]
      ).rows

    if settled?, do: rooms, else: allocate(rooms, amount, id, nil)
  end

  defp add_credit(_group, 0, rooms, lots), do: {rooms, lots}

  defp add_credit(group, amount, rooms, [{lot_id, balance} | lots]) do
    used = min(amount, balance)
    rooms = if group["status"] == "active", do: allocate(rooms, used, nil, lot_id), else: rooms
    lots = if used == balance, do: lots, else: [{lot_id, balance - used} | lots]
    add_credit(group, amount - used, rooms, lots)
  end

  defp allocate(rooms, 0, _payment_id, _lot_id), do: rooms

  defp allocate([{room_id, capacity} | rooms], amount, payment_id, lot_id) do
    used = min(capacity, amount)

    if used > 0 do
      repo().query!(
        """
        INSERT INTO room_allocations (room_id, cash_payment_id, credit_lot_id, amount_cents)
        VALUES (?, ?, ?, ?)
        """,
        [room_id, payment_id, lot_id, used]
      )
    end

    [{room_id, capacity - used} | allocate(rooms, amount - used, payment_id, lot_id)]
  end

  defp backfill_entitlements(group) do
    payments =
      rows("SELECT * FROM cash_payments WHERE group_id = ? ORDER BY id", [group["group_id"]])

    for lot <- rows("SELECT * FROM credit_lots WHERE source_group_id = ?", [group["group_id"]]) do
      Enum.reduce(payments, 0, fn payment, preceding ->
        cash = payment["converted_to_credit_cents"]

        if cash > 0 do
          amount = bonus_value(preceding + cash) - bonus_value(preceding)

          repo().query!(
            """
            INSERT INTO credit_entitlements (cash_payment_id, credit_lot_id, amount_cents)
            VALUES (?, ?, ?)
            """,
            [payment["id"], lot["id"], amount]
          )
        end

        preceding + cash
      end)
    end
  end

  defp bonus_value(cash), do: cash + div(cash * 10 + 50, 100)

  defp rows(sql, params \\ []) do
    %{columns: columns, rows: rows} = repo().query!(sql, params)
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end
end
