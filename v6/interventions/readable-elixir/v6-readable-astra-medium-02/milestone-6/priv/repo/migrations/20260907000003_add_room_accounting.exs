defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    create table(:cash_allocations) do
      add :group_id, references(:groups, column: :group_id, type: :string), null: false
      add :room_id, :string
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
      add :disposition, :string, null: false
      add :credit_lot_id, references(:credit_lots)
    end

    create index(:cash_allocations, [:payment_operation_id, :disposition])
    create index(:cash_allocations, [:group_id, :room_id])

    alter table(:credit_allocations) do
      add :room_id, :string
    end

    create index(:credit_allocations, [:credit_lot_id])

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:credit_entitlements) do
      add :payment_operation_id, :string, null: false
      add :credit_lot_id, references(:credit_lots), null: false
      add :amount_cents, :integer, null: false
    end

    create unique_index(:credit_entitlements, [:payment_operation_id, :credit_lot_id])
    flush()

    # Use the release's raw storage format, not application schemas which can
    # evolve independently of this migration. The migration and backfill are atomic.
    records_by_group =
      rows("SELECT operation_id, type, result FROM operations ORDER BY id")
      |> Enum.map(&Map.update!(&1, "result", fn value -> decode(value) end))
      |> Enum.filter(&(&1["result"]["status"] == "applied"))
      |> Enum.group_by(& &1["result"]["group_id"])

    for group <- rows("SELECT * FROM groups") do
      backfill(group, Map.get(records_by_group, group["group_id"], []))
    end
  end

  defp backfill(group, group_records) do
    rooms = decode(group["rooms"])

    nights =
      Date.diff(
        Date.from_iso8601!(group["departure_on"]),
        Date.from_iso8601!(group["arrival_on"])
      )

    rooms =
      Enum.map(rooms, fn room ->
        lodging = room["nightly_rate_cents"] * nights
        due = if group["rate_plan"] == "flexible", do: div(lodging * 20 + 50, 100), else: lodging

        Map.merge(room, %{
          "status" => "active",
          "lodging_total_cents" => lodging,
          "deposit_due_cents" => due,
          "cash_paid_cents" => 0,
          "credit_paid_cents" => 0
        })
      end)

    records =
      Enum.filter(group_records, &(&1["type"] in ["record_cash_payment", "apply_hotel_credit"]))

    recorded_cash = funding_total(records, "record_cash_payment")
    recorded_credit = funding_total(records, "apply_hotel_credit")
    legacy_cash = group["cash_paid_cents"] - recorded_cash
    legacy_credit = group["credit_paid_cents"] - recorded_credit

    if group["status"] == "active" do
      lots =
        rows("SELECT * FROM credit_allocations WHERE group_id = ? ORDER BY id", [
          group["group_id"]
        ])

      repo().query!("DELETE FROM credit_allocations WHERE group_id = ?", [group["group_id"]])
      rooms = allocate_cash(group, rooms, nil, legacy_cash, "held", nil)
      {rooms, lots} = allocate_credit(group, rooms, lots, legacy_credit)

      {rooms, []} =
        Enum.reduce(records, {rooms, lots}, fn record, {rooms, lots} ->
          amount = record["result"]["amount_cents"]

          if record["type"] == "record_cash_payment" do
            {allocate_cash(group, rooms, record["operation_id"], amount, "held", nil), lots}
          else
            allocate_credit(group, rooms, lots, amount)
          end
        end)

      save_rooms(group, rooms)
    else
      # Earlier releases only supported full cancellation. Every cash payment in
      # such a group shares its settlement disposition, even without an audit row.
      disposition =
        cond do
          group["cash_converted_to_credit_cents"] > 0 -> "converted_to_credit"
          group["refunded_cents"] > 0 -> "refunded"
          true -> "retained"
        end

      lot_id = if disposition == "converted_to_credit", do: cancellation_lot(group_records)

      payments =
        [{nil, legacy_cash}] ++
          for record <- records,
              record["type"] == "record_cash_payment",
              do: {record["operation_id"], record["result"]["amount_cents"]}

      Enum.reduce(payments, 0, fn {payment_id, amount}, preceding ->
        if amount > 0 do
          insert_cash(group["group_id"], nil, payment_id, amount, disposition, lot_id)

          if payment_id && lot_id do
            repo().query!(
              "INSERT INTO credit_entitlements (payment_operation_id, credit_lot_id, amount_cents) VALUES (?, ?, ?)",
              [payment_id, lot_id, bonus(preceding + amount) - bonus(preceding)]
            )
          end
        end

        preceding + amount
      end)

      save_rooms(group, Enum.map(rooms, &Map.put(&1, "status", "cancelled")))
    end
  end

  defp cancellation_lot(group_records) do
    # A legacy cancellation has no recorded payment contributors and therefore
    # needs no revocable entitlement rows.
    record = Enum.find(group_records, &(&1["type"] == "cancel_group"))

    if record do
      case rows("SELECT id FROM credit_lots WHERE source_operation_id = ?", [
             record["operation_id"]
           ]) do
        [lot] -> lot["id"]
        [] -> nil
      end
    end
  end

  defp allocate_cash(group, rooms, payment_id, amount, disposition, lot_id) do
    fill(rooms, amount, "cash_paid_cents", fn room_id, used ->
      insert_cash(group["group_id"], room_id, payment_id, used, disposition, lot_id)
    end)
  end

  defp allocate_credit(_group, rooms, lots, 0), do: {rooms, lots}

  defp allocate_credit(group, rooms, [lot | lots], amount) do
    used = min(lot["amount_cents"], amount)

    rooms =
      fill(rooms, used, "credit_paid_cents", fn room_id, cents ->
        repo().query!(
          "INSERT INTO credit_allocations (group_id, room_id, credit_lot_id, amount_cents) VALUES (?, ?, ?, ?)",
          [group["group_id"], room_id, lot["credit_lot_id"], cents]
        )
      end)

    lots =
      if used == lot["amount_cents"],
        do: lots,
        else: [Map.update!(lot, "amount_cents", &(&1 - used)) | lots]

    allocate_credit(group, rooms, lots, amount - used)
  end

  defp fill(rooms, amount, field, persist) do
    {rooms, 0} =
      Enum.map_reduce(rooms, amount, fn room, remaining ->
        used =
          min(
            room["deposit_due_cents"] - room["cash_paid_cents"] - room["credit_paid_cents"],
            remaining
          )

        if used > 0, do: persist.(room["room_id"], used)
        {Map.update!(room, field, &(&1 + used)), remaining - used}
      end)

    rooms
  end

  defp insert_cash(group_id, room_id, payment_id, amount, disposition, lot_id) do
    repo().query!(
      "INSERT INTO cash_allocations (group_id, room_id, payment_operation_id, amount_cents, disposition, credit_lot_id) VALUES (?, ?, ?, ?, ?, ?)",
      [group_id, room_id, payment_id, amount, disposition, lot_id]
    )
  end

  defp save_rooms(group, rooms),
    do:
      repo().query!("UPDATE groups SET rooms = ? WHERE group_id = ?", [
        Jason.encode!(rooms),
        group["group_id"]
      ])

  defp funding_total(records, type),
    do:
      records
      |> Enum.filter(&(&1["type"] == type))
      |> Enum.map(& &1["result"]["amount_cents"])
      |> Enum.sum()

  defp bonus(cash), do: cash + div(cash * 10 + 50, 100)
  defp decode(value) when is_binary(value), do: Jason.decode!(value)
  defp decode(value), do: value

  defp rows(sql, params \\ []) do
    %{columns: columns, rows: rows} = repo().query!(sql, params)
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end
end
