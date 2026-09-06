defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:credit_allocations) do
      add :room_id, :string
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create index(:credit_allocations, [:credit_lot_id])

    create table(:cash_allocations) do
      add :group_id, references(:groups, column: :group_id, type: :string), null: false
      add :room_id, :string
      add :payment_operation_id, :string
      add :funding_order, :integer, null: false, default: 0
      add :amount_cents, :integer, null: false
      add :disposition, :string, null: false
    end

    create index(:cash_allocations, [:group_id])
    create index(:cash_allocations, [:payment_operation_id])

    create table(:credit_entitlements) do
      add :payment_operation_id, :string, null: false
      add :credit_lot_id, references(:credit_lots), null: false
      add :amount_cents, :integer, null: false
    end

    create index(:credit_entitlements, [:payment_operation_id])
    flush()
    backfill()
  end

  def down do
    drop index(:credit_allocations, [:credit_lot_id])
    drop table(:credit_entitlements)
    drop table(:cash_allocations)
    alter table(:credit_allocations), do: remove(:room_id)
    alter table(:credit_lots), do: remove(:unrecovered_clawback_cents)
  end

  # Keep the upgrade independent of future application schemas and accounting code.
  defp rows(sql, params \\ []) do
    result = repo().query!(sql, params)
    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end

  defp backfill do
    operations =
      rows("SELECT * FROM operations ORDER BY id")
      |> Enum.map(fn op -> Map.put(op, "result", Jason.decode!(op["result"])) end)

    for group <- rows("SELECT * FROM groups") do
      rooms = Jason.decode!(group["rooms"])

      nights =
        Date.diff(
          Date.from_iso8601!(group["departure_on"]),
          Date.from_iso8601!(group["arrival_on"])
        )

      rooms =
        Enum.map(rooms, fn room ->
          lodging = room["nightly_rate_cents"] * nights

          due =
            if group["rate_plan"] == "flexible", do: div(lodging * 20 + 50, 100), else: lodging

          Map.merge(room, %{"status" => group["status"], "deposit_due_cents" => due})
        end)

      repo().query!("UPDATE groups SET rooms = ? WHERE group_id = ?", [
        Jason.encode!(rooms),
        group["group_id"]
      ])

      funding =
        Enum.filter(operations, fn op ->
          op["result"]["status"] == "applied" and op["result"]["group_id"] == group["group_id"] and
            op["type"] in ["record_cash_payment", "apply_hotel_credit"]
        end)

      payments = Enum.filter(funding, &(&1["type"] == "record_cash_payment"))
      recorded_cash = Enum.sum(Enum.map(payments, & &1["result"]["amount_cents"]))

      if group["status"] == "active" do
        credits =
          rows("SELECT * FROM credit_allocations WHERE group_id = ? ORDER BY id", [
            group["group_id"]
          ])

        recorded_credit =
          funding
          |> Enum.filter(&(&1["type"] == "apply_hotel_credit"))
          |> Enum.map(& &1["result"]["amount_cents"])
          |> Enum.sum()

        legacy_credit = Enum.sum(Enum.map(credits, & &1["amount_cents"])) - recorded_credit
        repo().query!("DELETE FROM credit_allocations WHERE group_id = ?", [group["group_id"]])
        state = {Enum.map(rooms, &{&1["room_id"], &1["deposit_due_cents"]}), credits}

        state =
          allocate_cash(state, group, max(group["cash_paid_cents"] - recorded_cash, 0), nil, 0)

        state = allocate_credit(state, group, max(legacy_credit, 0))

        Enum.reduce(funding, state, fn op, state ->
          if op["type"] == "record_cash_payment",
            do:
              allocate_cash(
                state,
                group,
                op["result"]["amount_cents"],
                op["operation_id"],
                op["id"]
              ),
            else: allocate_credit(state, group, op["result"]["amount_cents"])
        end)
      else
        disposition =
          cond do
            group["cash_converted_to_credit_cents"] > 0 -> "converted_to_credit"
            group["refunded_cents"] > 0 -> "refunded"
            true -> "retained"
          end

        total =
          group["cash_converted_to_credit_cents"] + group["refunded_cents"] +
            group["retained_cents"]

        legacy = max(total - recorded_cash, 0)
        if legacy > 0, do: insert_cash(group, nil, legacy, nil, 0, disposition)

        Enum.each(
          payments,
          &insert_cash(
            group,
            nil,
            &1["result"]["amount_cents"],
            &1["operation_id"],
            &1["id"],
            disposition
          )
        )

        if disposition == "converted_to_credit" do
          cancellation =
            Enum.find(
              operations,
              &(&1["type"] == "cancel_group" and &1["result"]["group_id"] == group["group_id"] and
                  &1["result"]["status"] == "applied")
            )

          lots =
            if cancellation,
              do:
                rows("SELECT id FROM credit_lots WHERE source_operation_id = ?", [
                  cancellation["operation_id"]
                ]),
              else: []

          for lot <- lots do
            Enum.reduce(payments, legacy, fn op, running ->
              next = running + op["result"]["amount_cents"]

              repo().query!(
                "INSERT INTO credit_entitlements (payment_operation_id, credit_lot_id, amount_cents) VALUES (?, ?, ?)",
                [op["operation_id"], lot["id"], bonus(next) - bonus(running)]
              )

              next
            end)
          end
        end

        repo().query!("UPDATE groups SET lodging_total_cents = 0 WHERE group_id = ?", [
          group["group_id"]
        ])
      end
    end
  end

  defp bonus(n), do: n + div(n * 10 + 50, 100)

  defp insert_cash(group, room, amount, payment, order, disposition) do
    repo().query!(
      "INSERT INTO cash_allocations (group_id, room_id, amount_cents, payment_operation_id, funding_order, disposition) VALUES (?, ?, ?, ?, ?, ?)",
      [group["group_id"], room, amount, payment, order, disposition]
    )
  end

  defp fill(rooms, amount, insert) do
    {rooms, left} =
      Enum.map_reduce(rooms, amount, fn {room, capacity}, left ->
        used = min(capacity, left)
        if used > 0, do: insert.(room, used)
        {{room, capacity - used}, left - used}
      end)

    if left != 0, do: raise("legacy funding exceeds room capacity")
    rooms
  end

  defp allocate_cash({rooms, credits}, group, amount, payment, order) do
    {fill(rooms, amount, &insert_cash(group, &1, &2, payment, order, "held")), credits}
  end

  defp allocate_credit(state, _group, 0), do: state

  defp allocate_credit({rooms, [lot | rest]}, group, amount) do
    used = min(amount, lot["amount_cents"])

    rooms =
      fill(rooms, used, fn room, cents ->
        repo().query!(
          "INSERT INTO credit_allocations (group_id, room_id, credit_lot_id, amount_cents) VALUES (?, ?, ?, ?)",
          [group["group_id"], room, lot["credit_lot_id"], cents]
        )
      end)

    remaining =
      if used == lot["amount_cents"],
        do: rest,
        else: [Map.update!(lot, "amount_cents", &(&1 - used)) | rest]

    allocate_credit({rooms, remaining}, group, amount - used)
  end
end
