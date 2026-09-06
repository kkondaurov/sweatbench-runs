defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :bigint, null: false, default: 0
      add :deposit_due_cents, :bigint, null: false, default: 0
      add :cash_paid_cents, :bigint, null: false, default: 0
      add :credit_paid_cents, :bigint, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :bigint, null: false, default: 0
    end

    create table(:payments, primary_key: false) do
      add :payment_operation_id, :string, primary_key: true
      add :original_group_id, references(:groups, column: :group_id, type: :string), null: false
      add :recorded_cents, :bigint, null: false
      add :refunded_cents, :bigint, null: false, default: 0
      add :retained_cents, :bigint, null: false, default: 0
      add :converted_to_credit_cents, :bigint, null: false, default: 0
      add :reduced_cents, :bigint, null: false, default: 0
      add :charged_back_cents, :bigint, null: false, default: 0
    end

    create table(:funding_allocations) do
      add :group_id, references(:groups, column: :group_id, type: :string), null: false
      add :room_id, references(:rooms), null: false

      add :payment_operation_id,
          references(:payments, column: :payment_operation_id, type: :string)

      add :credit_lot_id, references(:credit_lots)
      add :amount_cents, :bigint, null: false
    end

    create index(:funding_allocations, [:room_id])
    create index(:funding_allocations, [:payment_operation_id])

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots), null: false

      add :payment_operation_id,
          references(:payments, column: :payment_operation_id, type: :string), null: false

      add :amount_cents, :bigint, null: false
    end

    create unique_index(:credit_entitlements, [:payment_operation_id, :credit_lot_id])
    flush()
    backfill()
  end

  def down do
    # Restore the older release's historical lodging total on cancelled groups.
    execute "UPDATE groups SET lodging_total_cents = (SELECT SUM(lodging_total_cents) FROM rooms WHERE rooms.group_id = groups.group_id) WHERE status = 'cancelled'"
    drop table(:credit_entitlements)
    drop table(:funding_allocations)
    drop table(:payments)
    execute "ALTER TABLE credit_lots DROP COLUMN unrecovered_clawback_cents"

    for column <-
          ~w(status lodging_total_cents deposit_due_cents cash_paid_cents credit_paid_cents) do
      execute "ALTER TABLE rooms DROP COLUMN #{column}"
    end
  end

  # Use only this migration's SQL and integer arithmetic. Upgrades must not
  # depend on future application schemas or replay operations against live state.
  defp backfill do
    records =
      rows("SELECT * FROM operations ORDER BY id")
      |> Enum.map(fn row ->
        row
        |> Map.update!("result", &Jason.decode!/1)
        |> Map.update!("submission", &Jason.decode!/1)
      end)
      |> Enum.filter(&(&1["result"]["status"] == "applied"))

    groups = rows("SELECT * FROM groups ORDER BY group_id")
    credit_slices = credit_history(groups, records)
    records = Enum.group_by(records, & &1["result"]["group_id"])

    for group <- groups do
      id = group["group_id"]

      nights =
        Date.diff(
          Date.from_iso8601!(group["departure_on"]),
          Date.from_iso8601!(group["arrival_on"])
        )

      for room <- rows("SELECT * FROM rooms WHERE group_id = ? ORDER BY position", [id]) do
        lodging = room["nightly_rate_cents"] * nights

        due =
          cond do
            group["status"] == "cancelled" -> 0
            group["rate_plan"] == "flexible" -> div(lodging * 20 + 50, 100)
            true -> lodging
          end

        query(
          "UPDATE rooms SET status = ?, lodging_total_cents = ?, deposit_due_cents = ? WHERE id = ?",
          [group["status"], lodging, due, room["id"]]
        )
      end

      operations = Map.get(records, id, [])
      payments = Enum.filter(operations, &(&1["type"] == "record_cash_payment"))

      disposition =
        cond do
          group["status"] == "active" -> nil
          group["cash_converted_to_credit_cents"] > 0 -> "converted_to_credit_cents"
          group["cash_retained_cents"] > 0 -> "retained_cents"
          true -> "refunded_cents"
        end

      for payment <- payments do
        amount = payment["result"]["amount_cents"]

        query(
          "INSERT INTO payments (payment_operation_id, original_group_id, recorded_cents) VALUES (?, ?, ?)",
          [payment["operation_id"], id, amount]
        )

        if disposition do
          query("UPDATE payments SET #{disposition} = ? WHERE payment_operation_id = ?", [
            amount,
            payment["operation_id"]
          ])
        end
      end

      if group["status"] == "active" do
        allocate_active(group, operations, payments, credit_slices)
      else
        query("UPDATE groups SET lodging_total_cents = 0 WHERE group_id = ?", [id])

        if disposition == "converted_to_credit_cents",
          do: backfill_entitlements(group, operations, payments)
      end
    end
  end

  defp allocate_active(group, operations, payments, credit_slices) do
    id = group["group_id"]
    recorded_cash = Enum.sum(Enum.map(payments, & &1["result"]["amount_cents"]))

    recorded_credit =
      operations
      |> Enum.filter(&(&1["type"] == "apply_hotel_credit"))
      |> Enum.map(& &1["result"]["amount_cents"])
      |> Enum.sum()

    legacy_cash = group["deposit_paid_cents"] - group["credit_paid_cents"] - recorded_cash
    allocate(id, legacy_cash, nil, nil)

    lots =
      rows(
        """
        SELECT a.credit_lot_id, a.amount_cents, l.expires_on, l.source_operation_id, o.id AS issued_at
        FROM credit_allocations a JOIN credit_lots l ON l.id = a.credit_lot_id
        LEFT JOIN operations o ON o.operation_id = l.source_operation_id
        WHERE a.group_id = ? ORDER BY a.id
        """,
        [id]
      )

    # The pre-durability block is senior. Allocation IDs retain the original
    # consumption order of those lots; durable records retain later funding order.
    lots = consume_credit(id, group["credit_paid_cents"] - recorded_credit, lots)

    Enum.reduce(operations, lots, fn operation, lots ->
      case operation["type"] do
        "record_cash_payment" ->
          allocate(id, operation["result"]["amount_cents"], operation["operation_id"], nil)
          lots

        "apply_hotel_credit" ->
          case Map.fetch(credit_slices, operation["operation_id"]) do
            {:ok, slices} -> allocate_recorded_credit(id, slices, lots)
            :error -> consume_credit(id, operation["result"]["amount_cents"], lots, operation)
          end

        _ ->
          lots
      end
    end)
  end

  defp consume_credit(group_id, amount, lots, operation \\ nil) do
    {lots, remaining} =
      Enum.map_reduce(lots, amount, fn lot, remaining ->
        eligible =
          is_nil(operation) or
            (lot["expires_on"] >= operation["submission"]["occurred_on"] and
               (is_nil(lot["issued_at"]) or lot["issued_at"] < operation["id"]))

        used = if eligible, do: min(remaining, lot["amount_cents"]), else: 0
        allocate(group_id, used, nil, lot["credit_lot_id"])
        {Map.put(lot, "amount_cents", lot["amount_cents"] - used), remaining - used}
      end)

    if remaining != 0, do: raise("legacy credit does not reconcile")
    lots
  end

  defp allocate(_group_id, 0, _payment_id, _lot_id), do: :ok

  defp allocate(group_id, amount, payment_id, lot_id) when amount > 0 do
    rooms =
      rows("SELECT * FROM rooms WHERE group_id = ? AND status = 'active' ORDER BY position", [
        group_id
      ])

    field = if lot_id, do: "credit_paid_cents", else: "cash_paid_cents"

    remaining =
      Enum.reduce(rooms, amount, fn room, remaining ->
        used =
          min(
            remaining,
            room["deposit_due_cents"] - room["cash_paid_cents"] - room["credit_paid_cents"]
          )

        if used > 0 do
          query(
            "INSERT INTO funding_allocations (group_id, room_id, payment_operation_id, credit_lot_id, amount_cents) VALUES (?, ?, ?, ?, ?)",
            [group_id, room["id"], payment_id, lot_id, used]
          )

          query("UPDATE rooms SET #{field} = #{field} + ? WHERE id = ?", [used, room["id"]])
        end

        remaining - used
      end)

    if remaining != 0, do: raise("legacy funding does not reconcile with room deposits")
  end

  defp backfill_entitlements(group, operations, payments) do
    cancellation = Enum.find(operations, &(&1["type"] == "cancel_group"))

    if cancellation do
      [lot] =
        rows("SELECT id FROM credit_lots WHERE source_operation_id = ?", [
          cancellation["operation_id"]
        ])

      senior =
        group["cash_converted_to_credit_cents"] -
          Enum.sum(Enum.map(payments, & &1["result"]["amount_cents"]))

      Enum.reduce(payments, senior, fn payment, preceding ->
        amount = payment["result"]["amount_cents"]
        entitlement = bonus_value(preceding + amount) - bonus_value(preceding)

        query(
          "INSERT INTO credit_entitlements (credit_lot_id, payment_operation_id, amount_cents) VALUES (?, ?, ?)",
          [lot["id"], payment["operation_id"], entitlement]
        )

        preceding + amount
      end)
    end
  end

  # For guests whose lots all originated in this audit namespace, replay credit
  # availability in commit order. A restored earlier-expiring lot must not be
  # assigned to an application that happened while it was still held elsewhere.
  # Legacy lots have no issuance history; their aggregate allocations instead
  # retain the earlier release's original consumption order.
  defp credit_history(groups, operations) do
    lots = rows("SELECT * FROM credit_lots ORDER BY expires_on, source_operation_id, id")
    by_source = Map.new(operations, &{&1["operation_id"], &1})
    groups_by_id = Map.new(groups, &{&1["group_id"], &1})

    recorded_credit =
      operations
      |> Enum.filter(&(&1["type"] == "apply_hotel_credit"))
      |> Enum.group_by(& &1["result"]["group_id"])
      |> Map.new(fn {id, ops} ->
        {id, Enum.sum(Enum.map(ops, & &1["result"]["amount_cents"]))}
      end)

    legacy_guests =
      groups
      |> Enum.filter(
        &(&1["status"] == "active" and
            &1["credit_paid_cents"] > Map.get(recorded_credit, &1["group_id"], 0))
      )
      |> MapSet.new(& &1["guest_id"])

    replay_guests =
      lots
      |> Enum.group_by(& &1["guest_id"])
      |> Enum.filter(fn {guest, lots} ->
        not MapSet.member?(legacy_guests, guest) and
          Enum.all?(lots, fn lot ->
            case Map.get(by_source, lot["source_operation_id"]) do
              %{"type" => "cancel_group", "result" => %{"credit_issued_cents" => amount}} ->
                amount > 0

              _ ->
                false
            end
          end)
      end)
      |> MapSet.new(fn {guest, _lots} -> guest end)

    state = %{balances: Map.new(lots, &{&1["id"], 0}), held: %{}, slices: %{}}

    Enum.reduce(operations, state, fn operation, state ->
      group = Map.get(groups_by_id, operation["result"]["group_id"])

      if group && MapSet.member?(replay_guests, group["guest_id"]) do
        replay_credit(operation, group, lots, state)
      else
        state
      end
    end).slices
  end

  defp replay_credit(%{"type" => "apply_hotel_credit"} = operation, group, lots, state) do
    {slices, {balances, remaining}} =
      Enum.map_reduce(lots, {state.balances, operation["result"]["amount_cents"]}, fn lot,
                                                                                      {balances,
                                                                                       remaining} ->
        available = Map.fetch!(balances, lot["id"])

        used =
          if lot["guest_id"] == group["guest_id"] and
               lot["expires_on"] >= operation["submission"]["occurred_on"],
             do: min(remaining, available),
             else: 0

        {{lot["id"], used}, {Map.put(balances, lot["id"], available - used), remaining - used}}
      end)

    if remaining != 0, do: raise("durable credit history does not reconcile")
    slices = Enum.filter(slices, fn {_lot, amount} -> amount > 0 end)

    held =
      Enum.reduce(slices, Map.get(state.held, group["group_id"], %{}), fn {lot, amount}, held ->
        Map.update(held, lot, amount, &(&1 + amount))
      end)

    %{
      state
      | balances: balances,
        held: Map.put(state.held, group["group_id"], held),
        slices: Map.put(state.slices, operation["operation_id"], slices)
    }
  end

  defp replay_credit(%{"type" => "cancel_group"} = operation, group, lots, state) do
    on = operation["submission"]["occurred_on"]
    window = if group["policy_version"] == "flex-14", do: 14, else: 30

    refundable =
      group["rate_plan"] == "flexible" and
        Date.diff(Date.from_iso8601!(group["arrival_on"]), Date.from_iso8601!(on)) >= window

    held = Map.get(state.held, group["group_id"], %{})

    balances =
      Enum.reduce(lots, state.balances, fn lot, balances ->
        issued =
          if lot["source_operation_id"] == operation["operation_id"],
            do: operation["result"]["credit_issued_cents"],
            else: 0

        restored =
          if refundable and lot["expires_on"] >= on, do: Map.get(held, lot["id"], 0), else: 0

        Map.update!(balances, lot["id"], &(&1 + issued + restored))
      end)

    %{state | balances: balances, held: Map.delete(state.held, group["group_id"])}
  end

  defp replay_credit(_operation, _group, _lots, state), do: state

  defp allocate_recorded_credit(group_id, slices, lots) do
    Enum.reduce(slices, lots, fn {lot_id, amount}, lots ->
      allocate(group_id, amount, nil, lot_id)

      Enum.map(lots, fn lot ->
        if lot["credit_lot_id"] == lot_id do
          remaining = lot["amount_cents"] - amount
          if remaining < 0, do: raise("durable credit allocation does not reconcile")
          Map.put(lot, "amount_cents", remaining)
        else
          lot
        end
      end)
    end)
  end

  defp bonus_value(cash), do: cash + div(cash * 10 + 50, 100)
  defp query(sql, params), do: repo().query!(sql, params)

  defp rows(sql, params \\ []) do
    %{columns: columns, rows: rows} = query(sql, params)
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end
end
