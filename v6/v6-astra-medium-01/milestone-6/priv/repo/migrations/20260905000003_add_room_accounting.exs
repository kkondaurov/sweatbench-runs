defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:credit_allocations) do
      add :room_id, :string
      add :operation_id, :string
    end

    create index(:credit_allocations, [:credit_lot_id])

    create table(:cash_allocations) do
      add :group_id, references(:groups, column: :group_id, type: :string), null: false
      add :room_id, :string
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
      add :disposition, :string, null: false
    end

    create index(:cash_allocations, [:group_id])
    create index(:cash_allocations, [:payment_operation_id])

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots), null: false
      add :payment_operation_id, :string, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:credit_entitlements, [:payment_operation_id])
    flush()
    backfill()
  end

  # Keep the upgrade independent of application schemas and future business logic.
  defp rows(sql, params \\ []) do
    result = repo().query!(sql, params)
    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end

  defp write(sql, params), do: repo().query!(sql, params)
  defp decode(value) when is_binary(value), do: Jason.decode!(value)
  defp decode(value), do: value
  defp bonus(n), do: n + div(n * 10 + 50, 100)

  defp backfill do
    operations =
      rows("SELECT * FROM operations ORDER BY id")
      |> Enum.map(fn o -> Map.put(o, "result", decode(o["result"])) end)
      |> Enum.filter(&(&1["result"]["status"] == "applied"))
      |> Enum.group_by(& &1["result"]["group_id"])

    for g <- rows("SELECT * FROM groups") do
      rooms = decode(g["rooms"])

      nights =
        Date.diff(Date.from_iso8601!(g["departure_on"]), Date.from_iso8601!(g["arrival_on"]))

      rooms =
        Enum.map(rooms, fn r ->
          lodging = nights * r["nightly_rate_cents"]
          due = if g["rate_plan"] == "flexible", do: div(lodging * 20 + 50, 100), else: lodging

          Map.merge(r, %{
            "status" => g["status"],
            "lodging_total_cents" => lodging,
            "deposit_due_cents" => due,
            "cash_paid_cents" => 0,
            "credit_paid_cents" => 0
          })
        end)

      ops = Map.get(operations, g["group_id"], [])

      payments = Enum.filter(ops, &(&1["type"] == "record_cash_payment"))
      funding = Enum.filter(ops, &(&1["type"] in ["record_cash_payment", "apply_hotel_credit"]))

      legacy_cash =
        g["cash_paid_cents"] - Enum.sum(Enum.map(payments, & &1["result"]["amount_cents"]))

      if g["status"] == "active" do
        credits =
          rows("SELECT * FROM credit_allocations WHERE group_id = ? ORDER BY id", [g["group_id"]])

        legacy_credit =
          g["credit_paid_cents"] -
            Enum.sum(
              for o <- funding, o["type"] == "apply_hotel_credit", do: o["result"]["amount_cents"]
            )

        write("DELETE FROM credit_allocations WHERE group_id = ?", [g["group_id"]])
        rooms = allocate(rooms, g, legacy_cash, nil, nil)
        {rooms, credits} = allocate_credit(rooms, credits, g, legacy_credit, nil)

        {rooms, _} =
          Enum.reduce(funding, {rooms, credits}, fn o, {rs, cs} ->
            if o["type"] == "record_cash_payment" do
              {allocate(rs, g, o["result"]["amount_cents"], o["operation_id"], nil), cs}
            else
              allocate_credit(rs, cs, g, o["result"]["amount_cents"], o["operation_id"])
            end
          end)

        write("UPDATE groups SET rooms = ? WHERE group_id = ?", [
          Jason.encode!(rooms),
          g["group_id"]
        ])
      else
        disposition =
          cond do
            g["cash_converted_to_credit_cents"] > 0 -> "converted_to_credit"
            g["refunded_cents"] > 0 -> "refunded"
            true -> "retained"
          end

        blocks =
          [{nil, legacy_cash}] ++
            Enum.map(payments, &{&1["operation_id"], &1["result"]["amount_cents"]})

        for {id, amount} <- blocks, amount > 0 do
          cash(g, nil, id, amount, disposition)
        end

        if disposition == "converted_to_credit" do
          cancellation = Enum.find(ops, &(&1["type"] == "cancel_group"))

          if cancellation do
            for lot <-
                  rows("SELECT id FROM credit_lots WHERE source_operation_id = ?", [
                    cancellation["operation_id"]
                  ]) do
              Enum.reduce(blocks, 0, fn {id, amount}, total ->
                if id && amount > 0 do
                  write(
                    "INSERT INTO credit_entitlements (credit_lot_id, payment_operation_id, amount_cents) VALUES (?, ?, ?)",
                    [lot["id"], id, bonus(total + amount) - bonus(total)]
                  )
                end

                total + amount
              end)
            end
          end
        end

        write(
          "UPDATE groups SET rooms = ?, lodging_total_cents = 0, deposit_due_cents = 0, deposit_paid_cents = 0, cash_paid_cents = 0, credit_paid_cents = 0 WHERE group_id = ?",
          [Jason.encode!(rooms), g["group_id"]]
        )
      end
    end
  end

  defp cash(g, room, payment, amount, disposition) do
    write(
      "INSERT INTO cash_allocations (group_id, room_id, payment_operation_id, amount_cents, disposition) VALUES (?, ?, ?, ?, ?)",
      [g["group_id"], room, payment, amount, disposition]
    )
  end

  defp allocate(rooms, g, amount, operation, lot) do
    {rooms, 0} =
      Enum.map_reduce(rooms, amount, fn r, left ->
        used = min(left, r["deposit_due_cents"] - r["cash_paid_cents"] - r["credit_paid_cents"])
        key = if lot, do: "credit_paid_cents", else: "cash_paid_cents"

        if used > 0 do
          if lot do
            write(
              "INSERT INTO credit_allocations (group_id, room_id, operation_id, credit_lot_id, amount_cents) VALUES (?, ?, ?, ?, ?)",
              [g["group_id"], r["room_id"], operation, lot, used]
            )
          else
            cash(g, r["room_id"], operation, used, "held")
          end
        end

        {Map.update!(r, key, &(&1 + used)), left - used}
      end)

    rooms
  end

  defp allocate_credit(rooms, credits, _g, 0, _op), do: {rooms, credits}

  defp allocate_credit(rooms, [c | rest], g, amount, op) do
    used = min(amount, c["amount_cents"])
    rooms = allocate(rooms, g, used, op, c["credit_lot_id"])

    credits =
      if used == c["amount_cents"],
        do: rest,
        else: [Map.update!(c, "amount_cents", &(&1 - used)) | rest]

    allocate_credit(rooms, credits, g, amount - used, op)
  end

  def down do
    raise "Room settlements cannot be represented by the previous schema"
  end
end
