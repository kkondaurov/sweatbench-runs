defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    create table(:cash_payments) do
      add :payment_operation_id, :string, null: false
      add :original_group_id, references(:groups, column: :group_id, type: :string), null: false
      add :recorded_cents, :bigint, null: false
      add :refunded_cents, :bigint, null: false, default: 0
      add :retained_cents, :bigint, null: false, default: 0
      add :converted_to_credit_cents, :bigint, null: false, default: 0
      add :reduced_cents, :bigint, null: false, default: 0
      add :charged_back_cents, :bigint, null: false, default: 0
    end

    create unique_index(:cash_payments, [:payment_operation_id])

    create table(:room_fundings) do
      add :group_id, references(:groups, column: :group_id, type: :string), null: false
      add :room_id, :string, null: false

      add :payment_operation_id,
          references(:cash_payments, column: :payment_operation_id, type: :string)

      add :credit_lot_id, references(:credit_lots)
      add :amount_cents, :bigint, null: false
    end

    create index(:room_fundings, [:group_id])
    create index(:room_fundings, [:payment_operation_id])

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :bigint, null: false, default: 0
    end

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots), null: false

      add :payment_operation_id,
          references(:cash_payments, column: :payment_operation_id, type: :string), null: false

      add :amount_cents, :bigint, null: false
    end

    create unique_index(:credit_entitlements, [:credit_lot_id, :payment_operation_id])
    create index(:credit_entitlements, [:payment_operation_id])
    flush()

    # Keep this backfill independent of application schemas and business modules:
    # future code changes must not change the meaning of an already shipped migration.
    operations =
      rows("SELECT * FROM operations ORDER BY id")
      |> Enum.map(&Map.update!(&1, "result", fn json -> Jason.decode!(json) end))
      |> Enum.map(&Map.update!(&1, "payload", fn json -> Jason.decode!(json) end))
      |> Enum.filter(&(&1["result"]["status"] == "applied"))

    payments = Enum.filter(operations, &(&1["type"] == "record_cash_payment"))
    # Insert globally, rather than group by group, preserving durable commit order.
    Enum.each(payments, fn payment ->
      query(
        "INSERT INTO cash_payments (payment_operation_id, original_group_id, recorded_cents) VALUES (?, ?, ?)",
        [
          payment["operation_id"],
          payment["result"]["group_id"],
          payment["result"]["amount_cents"]
        ]
      )
    end)

    Enum.each(rows("SELECT * FROM groups ORDER BY group_id"), fn group ->
      funding =
        Enum.filter(
          operations,
          &(&1["result"]["group_id"] == group["group_id"] and
              &1["type"] in ["record_cash_payment", "apply_hotel_credit"])
        )

      rooms = priced_rooms(group)

      rooms =
        if group["status"] == "active", do: allocate_existing(group, rooms, funding), else: rooms

      query(
        "UPDATE groups SET rooms = ?, lodging_total_cents = ? WHERE group_id = ?",
        [
          Jason.encode!(rooms),
          if(group["status"] == "active", do: group["lodging_total_cents"], else: 0),
          group["group_id"]
        ]
      )

      if group["status"] == "cancelled", do: backfill_settlement(group, funding, operations)
    end)
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:room_fundings)
    drop table(:cash_payments)
    alter table(:credit_lots), do: remove(:unrecovered_clawback_cents)
  end

  defp priced_rooms(group) do
    nights =
      Date.diff(
        Date.from_iso8601!(group["departure_on"]),
        Date.from_iso8601!(group["arrival_on"])
      )

    Enum.map(Jason.decode!(group["rooms"]), fn room ->
      lodging = nights * room["nightly_rate_cents"]
      due = if group["rate_plan"] == "flexible", do: div(lodging * 20 + 50, 100), else: lodging

      Map.merge(room, %{
        "status" => group["status"],
        "lodging_total_cents" => lodging,
        "deposit_due_cents" => due,
        "cash_paid_cents" => 0,
        "credit_paid_cents" => 0
      })
    end)
  end

  defp allocate_existing(group, rooms, funding) do
    recorded_cash = funding_total(funding, "record_cash_payment")
    recorded_credit = funding_total(funding, "apply_hotel_credit")
    legacy_cash = group["deposit_paid_cents"] - group["credit_paid_cents"] - recorded_cash
    legacy_credit = group["credit_paid_cents"] - recorded_credit

    lots =
      rows(
        """
        SELECT a.credit_lot_id, a.amount_cents, l.expires_on, l.source_operation_id,
               o.id AS issued_order
        FROM credit_allocations a JOIN credit_lots l ON l.id = a.credit_lot_id
        LEFT JOIN operations o ON o.operation_id = l.source_operation_id
        WHERE a.group_id = ? ORDER BY a.id
        """,
        [group["group_id"]]
      )

    # The unattributed senior block consumes cash first, then legacy lots in their
    # original consumption order (the original allocation rows' insertion order).
    rooms = fill(rooms, group["group_id"], legacy_cash, nil, nil)
    {rooms, lots} = fill_credit(rooms, group["group_id"], lots, legacy_credit)

    {rooms, _lots} =
      Enum.reduce(funding, {rooms, lots}, fn operation, {rooms, lots} ->
        amount = operation["result"]["amount_cents"]

        if operation["type"] == "record_cash_payment" do
          {fill(rooms, group["group_id"], amount, operation["operation_id"], nil), lots}
        else
          # Occurrence dates affect lot eligibility, never the funding block's order.
          eligible =
            Enum.filter(lots, fn lot ->
              lot["expires_on"] >= operation["payload"]["occurred_on"] and
                (is_nil(lot["issued_order"]) or lot["issued_order"] < operation["id"])
            end)
            |> Enum.sort_by(&{&1["expires_on"], &1["source_operation_id"]})

          {rooms, consumed} = fill_credit(rooms, group["group_id"], eligible, amount)
          updated = Map.new(consumed, &{&1["credit_lot_id"], &1})
          {rooms, Enum.map(lots, &Map.get(updated, &1["credit_lot_id"], &1))}
        end
      end)

    rooms
  end

  defp fill_credit(rooms, group_id, lots, amount) do
    {lots, {rooms, remaining}} =
      Enum.map_reduce(lots, {rooms, amount}, fn lot, {rooms, remaining} ->
        used = min(lot["amount_cents"], remaining)
        rooms = fill(rooms, group_id, used, nil, lot["credit_lot_id"])
        {Map.put(lot, "amount_cents", lot["amount_cents"] - used), {rooms, remaining - used}}
      end)

    0 = remaining
    {rooms, lots}
  end

  defp fill(rooms, group_id, amount, payment_id, lot_id) when amount >= 0 do
    {rooms, remaining} =
      Enum.map_reduce(rooms, amount, fn room, remaining ->
        capacity = room["deposit_due_cents"] - room["cash_paid_cents"] - room["credit_paid_cents"]
        allocated = min(capacity, remaining)

        if allocated > 0 do
          query(
            "INSERT INTO room_fundings (group_id, room_id, payment_operation_id, credit_lot_id, amount_cents) VALUES (?, ?, ?, ?, ?)",
            [group_id, room["room_id"], payment_id, lot_id, allocated]
          )
        end

        key = if lot_id, do: "credit_paid_cents", else: "cash_paid_cents"
        {Map.update!(room, key, &(&1 + allocated)), remaining - allocated}
      end)

    0 = remaining
    rooms
  end

  defp backfill_settlement(group, funding, operations) do
    payments = Enum.filter(funding, &(&1["type"] == "record_cash_payment"))

    {column, cash} =
      cond do
        group["cash_converted_to_credit_cents"] > 0 ->
          {"converted_to_credit_cents", group["cash_converted_to_credit_cents"]}

        group["cash_refunded_cents"] > 0 ->
          {"refunded_cents", group["cash_refunded_cents"]}

        true ->
          {"retained_cents", group["cash_retained_cents"]}
      end

    Enum.each(payments, fn payment ->
      query(
        "UPDATE cash_payments SET #{column} = recorded_cents WHERE payment_operation_id = ?",
        [payment["operation_id"]]
      )
    end)

    if column == "converted_to_credit_cents" and payments != [] do
      cancellation =
        Enum.find(
          operations,
          &(&1["type"] == "cancel_group" and &1["result"]["group_id"] == group["group_id"])
        )

      [lot] =
        rows("SELECT id FROM credit_lots WHERE source_operation_id = ?", [
          cancellation["operation_id"]
        ])

      legacy_cash = cash - funding_total(payments, "record_cash_payment")

      Enum.reduce(payments, legacy_cash, fn payment, running ->
        next = running + payment["result"]["amount_cents"]
        entitlement = bonus_value(next) - bonus_value(running)

        query(
          "INSERT INTO credit_entitlements (credit_lot_id, payment_operation_id, amount_cents) VALUES (?, ?, ?)",
          [lot["id"], payment["operation_id"], entitlement]
        )

        next
      end)
    end
  end

  defp funding_total(operations, type) do
    operations
    |> Enum.filter(&(&1["type"] == type))
    |> Enum.map(& &1["result"]["amount_cents"])
    |> Enum.sum()
  end

  defp bonus_value(cash), do: cash + div(cash + 5, 10)
  defp query(sql, params), do: repo().query!(sql, params)

  defp rows(sql, params \\ []) do
    %{columns: columns, rows: rows} = query(sql, params)
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end
end
