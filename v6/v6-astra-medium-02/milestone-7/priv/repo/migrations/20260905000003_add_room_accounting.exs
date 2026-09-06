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

    create table(:room_funding) do
      add :group_id, :string, null: false
      add :room_id, :string, null: false
      add :payment_operation_id, :string
      add :credit_lot_id, references(:credit_lots)
      add :amount_cents, :integer, null: false
      add :disposition, :string, null: false
    end

    create index(:room_funding, [:group_id])
    create index(:room_funding, [:payment_operation_id])
    create index(:room_funding, [:credit_lot_id])

    create table(:credit_entitlements) do
      add :payment_operation_id, :string, null: false
      add :credit_lot_id, references(:credit_lots), null: false
      add :amount_cents, :integer, null: false
    end

    create unique_index(:credit_entitlements, [:payment_operation_id, :credit_lot_id])
    flush()
    backfill()
  end

  # Use the release's SQL representation rather than live application schemas so this
  # migration remains runnable after those schemas evolve.
  defp rows(sql, params \\ []) do
    %{columns: columns, rows: rows} = repo().query!(sql, params)
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end

  defp backfill do
    operations =
      rows("SELECT * FROM operations ORDER BY id")
      |> Enum.map(fn op -> Map.update!(op, "result", &Jason.decode!/1) end)
      |> Enum.filter(&(&1["result"]["status"] == "applied"))

    for group <- rows("SELECT * FROM groups") do
      nights =
        Date.diff(
          Date.from_iso8601!(group["departure_on"]),
          Date.from_iso8601!(group["arrival_on"])
        )

      rooms =
        Jason.decode!(group["rooms"])
        |> Enum.map(fn room ->
          lodging = room["nightly_rate_cents"] * nights

          due =
            if group["rate_plan"] == "flexible", do: div(lodging * 20 + 50, 100), else: lodging

          Map.merge(room, %{
            "status" => group["status"],
            "lodging_total_cents" => lodging,
            "deposit_due_cents" => due
          })
        end)

      repo().query!(
        "UPDATE groups SET rooms = ?, lodging_total_cents = ? WHERE group_id = ?",
        [
          Jason.encode!(rooms),
          if(group["status"] == "active", do: group["lodging_total_cents"], else: 0),
          group["group_id"]
        ]
      )

      recorded =
        Enum.filter(
          operations,
          &(&1["result"]["group_id"] == group["group_id"] and
              &1["type"] in ["record_cash_payment", "apply_hotel_credit"])
        )

      cash_ops = Enum.filter(recorded, &(&1["type"] == "record_cash_payment"))

      cash_total =
        group["cash_paid_cents"] + group["refunded_cents"] + group["retained_cents"] +
          group["cash_converted_to_credit_cents"]

      legacy_cash = cash_total - Enum.sum(Enum.map(cash_ops, & &1["result"]["amount_cents"]))

      credits =
        rows("SELECT * FROM credit_allocations WHERE group_id = ? ORDER BY id", [
          group["group_id"]
        ])

      recorded_credit =
        if group["status"] == "active",
          do:
            Enum.sum(
              for op <- recorded,
                  op["type"] == "apply_hotel_credit",
                  do: op["result"]["amount_cents"]
            ),
          else: 0

      legacy_credit = group["credit_paid_cents"] - recorded_credit
      {senior_credit, credits} = take_credit(credits, legacy_credit)
      blocks = [{nil, nil, legacy_cash}] ++ senior_credit

      {blocks, _} =
        Enum.reduce(recorded, {blocks, credits}, fn op, {blocks, credits} ->
          if op["type"] == "record_cash_payment" do
            {blocks ++ [{op["operation_id"], nil, op["result"]["amount_cents"]}], credits}
          else
            if group["status"] == "active" do
              {taken, rest} = take_credit(credits, op["result"]["amount_cents"])
              {blocks ++ taken, rest}
            else
              {blocks, credits}
            end
          end
        end)

      disposition =
        cond do
          group["status"] == "active" -> "held"
          group["cash_converted_to_credit_cents"] > 0 -> "converted_to_credit"
          group["refunded_cents"] > 0 -> "refunded"
          true -> "retained"
        end

      Enum.reduce(blocks, Enum.map(rooms, &{&1["room_id"], &1["deposit_due_cents"]}), fn {payment,
                                                                                          lot,
                                                                                          amount},
                                                                                         capacity ->
        {capacity, 0} =
          Enum.map_reduce(capacity, amount, fn {room_id, space}, remaining ->
            taken = min(space, remaining)

            if taken > 0 do
              repo().query!(
                "INSERT INTO room_funding (group_id, room_id, payment_operation_id, credit_lot_id, amount_cents, disposition) VALUES (?, ?, ?, ?, ?, ?)",
                [group["group_id"], room_id, payment, lot, taken, disposition]
              )
            end

            {{room_id, space - taken}, remaining - taken}
          end)

        capacity
      end)

      if disposition == "converted_to_credit" do
        cancellations =
          Enum.filter(
            operations,
            &(&1["type"] == "cancel_group" and &1["result"]["group_id"] == group["group_id"])
          )

        for cancellation <- cancellations,
            lot <-
              rows("SELECT id FROM credit_lots WHERE source_operation_id = ?", [
                cancellation["operation_id"]
              ]) do
          Enum.reduce(
            [
              {nil, legacy_cash}
              | Enum.map(cash_ops, &{&1["operation_id"], &1["result"]["amount_cents"]})
            ],
            0,
            fn {id, amount}, running ->
              if id != nil do
                repo().query!(
                  "INSERT INTO credit_entitlements (payment_operation_id, credit_lot_id, amount_cents) VALUES (?, ?, ?)",
                  [id, lot["id"], bonus(running + amount) - bonus(running)]
                )
              end

              running + amount
            end
          )
        end
      end
    end

    repo().query!("DELETE FROM credit_allocations")
  end

  defp bonus(amount), do: amount + div(amount * 10 + 50, 100)
  defp take_credit(credits, 0), do: {[], credits}

  defp take_credit([credit | rest], needed) do
    taken = min(needed, credit["amount_cents"])

    remaining =
      if taken == credit["amount_cents"],
        do: rest,
        else: [Map.put(credit, "amount_cents", credit["amount_cents"] - taken) | rest]

    {tail, remaining} = take_credit(remaining, needed - taken)
    {[{nil, credit["credit_lot_id"], taken} | tail], remaining}
  end

  def down do
    raise "Room funding history cannot be downgraded to aggregate accounting"
  end
end
