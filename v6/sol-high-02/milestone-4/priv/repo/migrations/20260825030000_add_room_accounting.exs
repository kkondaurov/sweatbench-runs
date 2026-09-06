defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :text, null: false, default: "active"
      add :lodging_total_cents, :integer
      add :deposit_due_cents, :integer
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:ledger) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
    end

    create table(:cash_payments, primary_key: false) do
      add :payment_operation_id, :text, primary_key: true
      add :group_id, references(:groups, column: :group_id, type: :text), null: false
      add :recorded_cents, :integer, null: false
      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
    end

    create index(:cash_payments, [:group_id])

    create table(:room_cash_allocations) do
      add :group_id, references(:groups, column: :group_id, type: :text), null: false
      add :room_id, references(:rooms, on_delete: :delete_all), null: false

      add :payment_operation_id,
          references(:cash_payments, column: :payment_operation_id, type: :text)

      add :funding_operation_id, :text
      add :amount_cents, :integer, null: false
    end

    create index(:room_cash_allocations, [:group_id, :room_id])
    create index(:room_cash_allocations, [:payment_operation_id])

    create table(:room_credit_allocations) do
      add :group_id, references(:groups, column: :group_id, type: :text), null: false
      add :room_id, references(:rooms, on_delete: :delete_all), null: false
      add :credit_lot_id, references(:credit_lots, on_delete: :restrict), null: false
      add :funding_operation_id, :text
      add :amount_cents, :integer, null: false
    end

    create index(:room_credit_allocations, [:group_id, :room_id])
    create index(:room_credit_allocations, [:credit_lot_id])

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false

      add :payment_operation_id,
          references(:cash_payments, column: :payment_operation_id, type: :text)

      add :principal_cents, :integer, null: false
      add :entitlement_cents, :integer, null: false
    end

    create index(:credit_entitlements, [:payment_operation_id])

    flush()
    backfill_rooms_and_funding()
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:room_credit_allocations)
    drop table(:room_cash_allocations)
    drop table(:cash_payments)

    alter table(:ledger) do
      remove :cash_reduced_cents
      remove :cash_charged_back_cents
    end

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:rooms) do
      remove :status
      remove :lodging_total_cents
      remove :deposit_due_cents
    end
  end

  defp backfill_rooms_and_funding do
    %{rows: groups} =
      repo().query!(
        "SELECT group_id, arrival_on, departure_on, rate_plan, status, cash_paid_cents, credit_paid_cents FROM groups"
      )

    Enum.each(groups, &backfill_group/1)
  end

  defp backfill_group([group_id, arrival, departure, rate_plan, status, cash_total, credit_total]) do
    {:ok, arrival_on} = Date.from_iso8601(arrival)
    {:ok, departure_on} = Date.from_iso8601(departure)
    nights = Date.diff(departure_on, arrival_on)

    %{rows: room_rows} =
      repo().query!(
        "SELECT id, nightly_rate_cents FROM rooms WHERE group_id = ? ORDER BY position",
        [group_id]
      )

    rooms =
      Enum.map(room_rows, fn [id, rate] ->
        lodging = nights * rate
        due = if rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging
        room_status = if status == "active", do: "active", else: "cancelled"

        repo().query!(
          "UPDATE rooms SET status = ?, lodging_total_cents = ?, deposit_due_cents = ? WHERE id = ?",
          [room_status, lodging, due, id]
        )

        %{id: id, due: due, funded: 0}
      end)

    records = durable_funding(group_id)

    durable_cash =
      records
      |> Enum.filter(&(&1.type == "record_cash_payment"))
      |> Enum.map(& &1.amount)
      |> Enum.sum()

    durable_credit =
      records
      |> Enum.filter(&(&1.type == "apply_hotel_credit"))
      |> Enum.map(& &1.amount)
      |> Enum.sum()

    legacy_cash = max(cash_total - durable_cash, 0)
    legacy_credit = max(credit_total - durable_credit, 0)

    if status == "active" do
      credit_queue = credit_queue(group_id)
      rooms = allocate_cash(rooms, group_id, nil, nil, legacy_cash)
      {rooms, credit_queue} = allocate_credit(rooms, group_id, nil, legacy_credit, credit_queue)

      {_rooms, _queue} =
        Enum.reduce(records, {rooms, credit_queue}, fn record, {room_state, queue} ->
          if record.type == "record_cash_payment" do
            insert_payment(record.operation_id, group_id, record.amount, :held)

            {allocate_cash(
               room_state,
               group_id,
               record.operation_id,
               record.operation_id,
               record.amount
             ), queue}
          else
            allocate_credit(room_state, group_id, record.operation_id, record.amount, queue)
          end
        end)
    else
      settlement = cancellation_settlement(group_id)

      Enum.each(records, fn record ->
        if record.type == "record_cash_payment" do
          insert_payment(record.operation_id, group_id, record.amount, settlement.kind)
        end
      end)

      if settlement.kind == :converted do
        contributors =
          [%{operation_id: nil, amount: legacy_cash}] ++
            (records
             |> Enum.filter(&(&1.type == "record_cash_payment"))
             |> Enum.map(&%{operation_id: &1.operation_id, amount: &1.amount}))

        create_entitlements(settlement.operation_id, contributors)
      end

      repo().query!(
        "UPDATE groups SET lodging_total_cents = 0, deposit_due_cents = 0, deposit_paid_cents = 0, cash_paid_cents = 0, credit_paid_cents = 0 WHERE group_id = ?",
        [group_id]
      )
    end
  end

  defp durable_funding(group_id) do
    %{rows: rows} =
      repo().query!(
        "SELECT operation_id, operation_type, result FROM operation_records WHERE operation_type IN ('record_cash_payment', 'apply_hotel_credit') ORDER BY id"
      )

    rows
    |> Enum.map(fn [operation_id, type, result] ->
      result = decode_json(result)

      %{
        operation_id: operation_id,
        type: type,
        amount: result["amount_cents"],
        group_id: result["group_id"],
        status: result["status"]
      }
    end)
    |> Enum.filter(&(&1.status == "applied" and &1.group_id == group_id))
  end

  defp credit_queue(group_id) do
    %{rows: rows} =
      repo().query!(
        "SELECT credit_lot_id, amount_cents FROM credit_allocations WHERE group_id = ? ORDER BY id",
        [group_id]
      )

    Enum.map(rows, fn [lot_id, amount] -> %{lot_id: lot_id, amount: amount} end)
  end

  defp allocate_cash(rooms, _group_id, _payment_id, _funding_id, 0), do: rooms

  defp allocate_cash(rooms, group_id, payment_id, funding_id, amount) do
    {updated, remaining} =
      allocate_rooms(rooms, amount, fn room_id, allocated ->
        repo().query!(
          "INSERT INTO room_cash_allocations (group_id, room_id, payment_operation_id, funding_operation_id, amount_cents) VALUES (?, ?, ?, ?, ?)",
          [group_id, room_id, payment_id, funding_id, allocated]
        )
      end)

    if remaining != 0, do: raise("room cash backfill exceeded deposit")
    updated
  end

  defp allocate_credit(rooms, _group_id, _funding_id, 0, queue), do: {rooms, queue}

  defp allocate_credit(rooms, group_id, funding_id, amount, queue) do
    {chunks, queue} = take_credit(queue, amount, [])

    rooms =
      Enum.reduce(chunks, rooms, fn {lot_id, chunk}, room_state ->
        {updated, remaining} =
          allocate_rooms(room_state, chunk, fn room_id, allocated ->
            repo().query!(
              "INSERT INTO room_credit_allocations (group_id, room_id, credit_lot_id, funding_operation_id, amount_cents) VALUES (?, ?, ?, ?, ?)",
              [group_id, room_id, lot_id, funding_id, allocated]
            )
          end)

        if remaining != 0, do: raise("room credit backfill exceeded deposit")
        updated
      end)

    {rooms, queue}
  end

  defp allocate_rooms(rooms, amount, inserter) do
    Enum.map_reduce(rooms, amount, fn room, remaining ->
      capacity = room.due - room.funded
      allocated = min(capacity, remaining)
      if allocated > 0, do: inserter.(room.id, allocated)
      {%{room | funded: room.funded + allocated}, remaining - allocated}
    end)
  end

  defp take_credit(queue, 0, chunks), do: {Enum.reverse(chunks), queue}
  defp take_credit([], _remaining, _chunks), do: raise("credit backfill lacks lot allocations")

  defp take_credit([lot | rest], remaining, chunks) do
    amount = min(lot.amount, remaining)
    next = if amount == lot.amount, do: rest, else: [%{lot | amount: lot.amount - amount} | rest]
    take_credit(next, remaining - amount, [{lot.lot_id, amount} | chunks])
  end

  defp insert_payment(operation_id, group_id, amount, disposition) do
    columns = %{
      held: "held_cents",
      refunded: "refunded_cents",
      retained: "retained_cents",
      converted: "converted_to_credit_cents"
    }

    column = Map.fetch!(columns, disposition)

    repo().query!(
      "INSERT INTO cash_payments (payment_operation_id, group_id, recorded_cents, #{column}) VALUES (?, ?, ?, ?)",
      [operation_id, group_id, amount, amount]
    )
  end

  defp cancellation_settlement(group_id) do
    %{rows: rows} =
      repo().query!(
        "SELECT operation_id, result FROM operation_records WHERE operation_type = 'cancel_group' ORDER BY id",
        []
      )

    Enum.find_value(Enum.reverse(rows), %{kind: :retained, operation_id: nil}, fn [
                                                                                    operation_id,
                                                                                    result
                                                                                  ] ->
      result = decode_json(result)

      if result["status"] == "applied" and result["group_id"] == group_id do
        kind =
          cond do
            result["credit_issued_cents"] > 0 -> :converted
            result["refunded_cents"] > 0 -> :refunded
            true -> :retained
          end

        %{kind: kind, operation_id: operation_id}
      end
    end)
  end

  defp create_entitlements(nil, _contributors), do: :ok

  defp create_entitlements(source_operation_id, contributors) do
    %{rows: rows} =
      repo().query!(
        "SELECT id FROM credit_lots WHERE source_operation_id = ? ORDER BY id LIMIT 1",
        [source_operation_id]
      )

    case rows do
      [[lot_id]] ->
        contributors
        |> Enum.reject(&(&1.amount == 0))
        |> Enum.reduce(0, fn contributor, running ->
          entitlement = bonus_value(running + contributor.amount) - bonus_value(running)

          repo().query!(
            "INSERT INTO credit_entitlements (credit_lot_id, payment_operation_id, principal_cents, entitlement_cents) VALUES (?, ?, ?, ?)",
            [lot_id, contributor.operation_id, contributor.amount, entitlement]
          )

          running + contributor.amount
        end)

      [] ->
        :ok
    end
  end

  defp bonus_value(principal), do: principal + div(principal * 10 + 50, 100)
  defp decode_json(value) when is_map(value), do: value
  defp decode_json(value) when is_binary(value), do: Jason.decode!(value)
end
