defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    create table(:cash_allocations) do
      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :delete_all),
          null: false

      add :room_id, :string
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
      add :disposition, :string, null: false
    end

    create index(:cash_allocations, [:group_id, :disposition])
    create index(:cash_allocations, [:payment_operation_id])

    alter table(:credit_allocations) do
      add :room_id, :string
      add :operation_id, :string
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:credit_entitlements) do
      add :payment_operation_id, :string, null: false
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :amount_cents, :integer, null: false
    end

    create unique_index(:credit_entitlements, [:payment_operation_id, :credit_lot_id])
    flush()
    backfill()
  end

  def down do
    drop table(:credit_entitlements)
    alter table(:credit_lots), do: remove(:unrecovered_clawback_cents)

    alter table(:credit_allocations) do
      remove :room_id
      remove :operation_id
    end

    drop table(:cash_allocations)
  end

  # This backfill deliberately uses only the release's SQL/JSON representation,
  # not application schemas whose meaning can change in subsequent releases.
  defp backfill do
    records_by_group =
      rows("SELECT operation_id, type, result FROM partner_operations ORDER BY id")
      |> Enum.map(&Map.update!(&1, "result", fn result -> Jason.decode!(result) end))
      |> Enum.group_by(& &1["result"]["group_id"])

    for group <- rows("SELECT * FROM groups") do
      records = Map.get(records_by_group, group["group_id"], [])

      funding =
        Enum.filter(records, fn record ->
          result = record["result"]

          record["type"] in ["record_cash_payment", "apply_hotel_credit"] and
            result["status"] == "applied" and result["group_id"] == group["group_id"]
        end)

      payments = Enum.filter(funding, &(&1["type"] == "record_cash_payment"))

      legacy_cash =
        group["deposit_paid_cents"] - group["credit_paid_cents"] -
          Enum.sum(Enum.map(payments, &amount/1))

      cash_blocks = [{nil, legacy_cash} | Enum.map(payments, &{&1["operation_id"], amount(&1)})]

      if group["status"] == "active" do
        backfill_active(group, funding, legacy_cash)
      else
        disposition =
          cond do
            group["converted_cents"] > 0 -> "converted_to_credit"
            group["retained_cents"] > 0 -> "retained"
            true -> "refunded"
          end

        for {id, cash} <- cash_blocks, cash > 0 do
          insert_cash(group["group_id"], nil, id, cash, disposition)
        end

        if disposition == "converted_to_credit",
          do: backfill_entitlements(group, cash_blocks, records)

        repo().query!(
          "UPDATE groups SET lodging_total_cents = 0, deposit_due_cents = 0, deposit_paid_cents = 0, credit_paid_cents = 0 WHERE group_id = ?",
          [group["group_id"]]
        )
      end
    end
  end

  defp backfill_active(group, funding, legacy_cash) do
    id = group["group_id"]
    allocations = rows("SELECT * FROM credit_allocations WHERE group_id = ? ORDER BY id", [id])
    credit = Enum.map(allocations, &{&1["credit_lot_id"], &1["amount_cents"]})

    recorded_credit =
      funding
      |> Enum.filter(&(&1["type"] == "apply_hotel_credit"))
      |> Enum.map(&amount/1)
      |> Enum.sum()

    legacy_credit = group["credit_paid_cents"] - recorded_credit
    repo().query!("DELETE FROM credit_allocations WHERE group_id = ?", [id])

    nights =
      Date.diff(
        Date.from_iso8601!(group["departure_on"]),
        Date.from_iso8601!(group["arrival_on"])
      )

    capacity =
      Enum.map(Jason.decode!(group["rooms"]), fn room ->
        lodging = nights * room["nightly_rate_cents"]
        due = if group["rate_plan"] == "flexible", do: div(lodging * 20 + 50, 100), else: lodging
        {room["room_id"], due}
      end)

    capacity = allocate(capacity, legacy_cash, &insert_cash(id, &1, nil, &2, "held"))
    {capacity, credit} = allocate_credit(capacity, credit, legacy_credit, id, nil)

    Enum.reduce(funding, {capacity, credit}, fn record, {space, lots} ->
      if record["type"] == "record_cash_payment" do
        {allocate(
           space,
           amount(record),
           &insert_cash(id, &1, record["operation_id"], &2, "held")
         ), lots}
      else
        allocate_credit(space, lots, amount(record), id, record["operation_id"])
      end
    end)
  end

  defp allocate_credit(space, lots, 0, _, _), do: {space, lots}

  defp allocate_credit(space, [{lot, balance} | rest], amount, group, operation) do
    used = min(balance, amount)

    space =
      allocate(space, used, fn room, cents ->
        repo().query!(
          "INSERT INTO credit_allocations (group_id, room_id, operation_id, credit_lot_id, amount_cents) VALUES (?, ?, ?, ?, ?)",
          [group, room, operation, lot, cents]
        )
      end)

    lots = if used == balance, do: rest, else: [{lot, balance - used} | rest]
    allocate_credit(space, lots, amount - used, group, operation)
  end

  defp allocate(space, 0, _), do: space

  defp allocate([{room, available} | rest], amount, insert) do
    used = min(available, amount)
    if used > 0, do: insert.(room, used)
    [{room, available - used} | allocate(rest, amount - used, insert)]
  end

  defp backfill_entitlements(group, blocks, records) do
    # Before this release a group could issue at most one lot, on full cancellation.
    cancellation =
      Enum.find(records, fn record ->
        result = record["result"]

        record["type"] == "cancel_group" and result["status"] == "applied" and
          result["group_id"] == group["group_id"]
      end)

    if cancellation do
      for lot <-
            rows("SELECT id FROM credit_lots WHERE source_operation_id = ?", [
              cancellation["operation_id"]
            ]) do
        Enum.reduce(blocks, 0, fn {payment, cash}, preceding ->
          through = preceding + cash

          if payment do
            repo().query!(
              "INSERT INTO credit_entitlements (payment_operation_id, credit_lot_id, amount_cents) VALUES (?, ?, ?)",
              [payment, lot["id"], bonus(through) - bonus(preceding)]
            )
          end

          through
        end)
      end
    end
  end

  defp bonus(cash), do: cash + div(cash * 10 + 50, 100)
  defp amount(record), do: record["result"]["amount_cents"]

  defp insert_cash(group, room, payment, amount, disposition) do
    repo().query!(
      "INSERT INTO cash_allocations (group_id, room_id, payment_operation_id, amount_cents, disposition) VALUES (?, ?, ?, ?, ?)",
      [group, room, payment, amount, disposition]
    )
  end

  defp rows(sql, params \\ []) do
    %{columns: columns, rows: rows} = repo().query!(sql, params)
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end
end
