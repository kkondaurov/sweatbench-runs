defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    create table(:room_allocations) do
      add :group_id, references(:groups, column: :group_id, type: :string), null: false
      add :room_id, :string
      add :kind, :string, null: false
      # Nullable for the senior block predating durable operations. No FK: the
      # current operation's audit record is inserted after its domain changes.
      add :funding_operation_id, :string
      add :credit_lot_id, references(:credit_lots)
      add :amount_cents, :integer, null: false
      add :disposition, :string, null: false
    end

    create index(:room_allocations, [:group_id, :disposition])
    create index(:room_allocations, [:funding_operation_id])

    create table(:credit_entitlements) do
      add :payment_operation_id, :string
      add :credit_lot_id, references(:credit_lots), null: false
      add :amount_cents, :integer, null: false
    end

    create index(:credit_entitlements, [:payment_operation_id])

    create table(:credit_clawbacks, primary_key: false) do
      add :credit_lot_id, references(:credit_lots), primary_key: true
      add :unrecovered_cents, :integer, null: false, default: 0
    end

    flush()
    backfill()
  end

  def down do
    drop table(:credit_clawbacks)
    drop table(:credit_entitlements)
    drop table(:room_allocations)
    # This removes provenance, not settlements; see the runbook before downgrading.
  end

  # Deliberately use the release's SQL/JSON format, not evolving application schemas.
  defp rows(sql, params \\ []) do
    %{columns: columns, rows: rows} = repo().query!(sql, params)
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end

  defp backfill do
    operations =
      rows("SELECT * FROM operations ORDER BY id")
      |> Enum.map(fn op -> Map.put(op, "result", Jason.decode!(op["result"])) end)
      |> Enum.filter(&(&1["result"]["status"] == "applied"))

    for group <- rows("SELECT * FROM groups ORDER BY group_id") do
      id = group["group_id"]
      records = Enum.filter(operations, &(&1["result"]["group_id"] == id))
      payments = Enum.filter(records, &(&1["type"] == "record_cash_payment"))
      credit_ops = Enum.filter(records, &(&1["type"] == "apply_hotel_credit"))

      nights =
        Date.diff(
          Date.from_iso8601!(group["departure_on"]),
          Date.from_iso8601!(group["arrival_on"])
        )

      rooms =
        Jason.decode!(group["rooms"])
        |> Enum.map(fn room ->
          room = if is_binary(room), do: Jason.decode!(room), else: room
          lodging = nights * room["nightly_rate_cents"]

          due =
            if group["rate_plan"] == "flexible", do: div(lodging * 20 + 50, 100), else: lodging

          Map.merge(room, %{
            "status" => group["status"],
            "lodging_total_cents" => lodging,
            "deposit_due_cents" => due,
            "cash_paid_cents" => 0,
            "credit_paid_cents" => 0
          })
        end)

      rooms =
        if group["status"] == "active" do
          legacy_cash = group["cash_paid_cents"] - sum_payments(payments)
          legacy_credit = group["credit_paid_cents"] - sum_payments(credit_ops)
          lots = rows("SELECT * FROM credit_allocations WHERE group_id = ? ORDER BY id", [id])
          rooms = allocate(rooms, id, legacy_cash, "cash", nil, nil)
          {rooms, lots} = allocate_credit(rooms, lots, id, legacy_credit, nil)

          {rooms, []} =
            Enum.reduce(records, {rooms, lots}, fn op, {rooms, lots} ->
              case op["type"] do
                "record_cash_payment" ->
                  {allocate(
                     rooms,
                     id,
                     op["result"]["amount_cents"],
                     "cash",
                     op["operation_id"],
                     nil
                   ), lots}

                "apply_hotel_credit" ->
                  allocate_credit(
                    rooms,
                    lots,
                    id,
                    op["result"]["amount_cents"],
                    op["operation_id"]
                  )

                _ ->
                  {rooms, lots}
              end
            end)

          rooms
        else
          disposition =
            cond do
              group["cash_converted_to_credit_cents"] > 0 -> "converted_to_credit"
              group["cash_retained_cents"] > 0 -> "retained"
              true -> "refunded"
            end

          total =
            group["cash_converted_to_credit_cents"] + group["cash_retained_cents"] +
              group["cash_refunded_cents"]

          blocks = [
            {nil, total - sum_payments(payments)}
            | Enum.map(payments, &{&1["operation_id"], &1["result"]["amount_cents"]})
          ]

          lot =
            if disposition == "converted_to_credit" do
              rows(
                "SELECT l.* FROM credit_lots l JOIN operations o ON o.operation_id = l.source_operation_id WHERE json_extract(o.result, '$.group_id') = ? AND o.type = 'cancel_group'",
                [id]
              )
              |> List.first()
            end

          Enum.reduce(blocks, 0, fn {payment_id, amount}, preceding ->
            if amount > 0 do
              insert_slice(id, nil, amount, "cash", payment_id, nil, disposition)

              if lot do
                repo().query!(
                  "INSERT INTO credit_entitlements (payment_operation_id, credit_lot_id, amount_cents) VALUES (?, ?, ?)",
                  [payment_id, lot["id"], bonus(preceding + amount) - bonus(preceding)]
                )
              end
            end

            preceding + amount
          end)

          rooms
        end

      lodging = if group["status"] == "active", do: group["lodging_total_cents"], else: 0

      repo().query!("UPDATE groups SET rooms = ?, lodging_total_cents = ? WHERE group_id = ?", [
        Jason.encode!(rooms),
        lodging,
        id
      ])
    end
  end

  defp sum_payments(operations),
    do: Enum.sum(Enum.map(operations, & &1["result"]["amount_cents"]))

  defp bonus(cash), do: cash + div(cash * 10 + 50, 100)

  defp allocate(rooms, group_id, amount, kind, operation_id, lot_id) do
    {rooms, 0} =
      Enum.map_reduce(rooms, amount, fn room, needed ->
        used =
          min(
            needed,
            room["deposit_due_cents"] - room["cash_paid_cents"] - room["credit_paid_cents"]
          )

        if used > 0,
          do: insert_slice(group_id, room["room_id"], used, kind, operation_id, lot_id, "held")

        {Map.update!(room, kind <> "_paid_cents", &(&1 + used)), needed - used}
      end)

    rooms
  end

  defp allocate_credit(rooms, lots, _, 0, _), do: {rooms, lots}

  defp allocate_credit(rooms, [lot | rest], group_id, amount, operation_id) do
    used = min(amount, lot["amount_cents"])
    rooms = allocate(rooms, group_id, used, "credit", operation_id, lot["credit_lot_id"])

    lots =
      if used == lot["amount_cents"],
        do: rest,
        else: [Map.update!(lot, "amount_cents", &(&1 - used)) | rest]

    allocate_credit(rooms, lots, group_id, amount - used, operation_id)
  end

  defp insert_slice(group_id, room_id, amount, kind, operation_id, lot_id, disposition) do
    repo().query!(
      "INSERT INTO room_allocations (group_id, room_id, amount_cents, kind, funding_operation_id, credit_lot_id, disposition) VALUES (?, ?, ?, ?, ?, ?, ?)",
      [group_id, room_id, amount, kind, operation_id, lot_id, disposition]
    )
  end
end
