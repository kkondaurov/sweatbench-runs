defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :text, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
    end

    alter table(:groups) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:room_allocations) do
      add :room_id, references(:rooms), null: false
      add :payment_operation_id, :text
      add :credit_lot_id, references(:credit_lots)
      add :amount_cents, :integer, null: false

      add :disposition, :text,
        null: false,
        default: "held",
        check: %{
          name: "valid_room_allocation",
          expr:
            "amount_cents > 0 AND disposition IN ('held', 'refunded', 'retained', 'converted_to_credit', 'reduced', 'charged_back') AND (credit_lot_id IS NULL OR (payment_operation_id IS NULL AND disposition = 'held'))"
        }
    end

    create index(:room_allocations, [:room_id, :disposition])
    create index(:room_allocations, [:payment_operation_id])
    create index(:room_allocations, [:credit_lot_id])

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots), null: false
      add :payment_operation_id, :text
      add :amount_cents, :integer, null: false
    end

    create index(:credit_entitlements, [:payment_operation_id])
    flush()
    backfill()
  end

  # This migration deliberately uses SQL and plain maps, not application schemas:
  # future schema changes must not change how an earlier database is upgraded.
  defp backfill do
    records =
      rows("SELECT * FROM operation_records ORDER BY id")
      |> Enum.map(fn record ->
        record
        |> Map.update!("result", &Jason.decode!/1)
        |> Map.update!("payload", &Jason.decode!/1)
      end)
      |> Enum.filter(&(&1["result"]["status"] == "applied"))

    by_group = Enum.group_by(records, & &1["result"]["group_id"])
    issuance_order = Map.new(records, &{&1["operation_id"], &1["id"]})

    for group <- rows("SELECT * FROM groups") do
      rooms = price_rooms(group)
      funding = Map.get(by_group, group["group_id"], [])
      payments = Enum.filter(funding, &(&1["type"] == "record_cash_payment"))
      recorded_cash = funding_total(payments)

      if group["status"] == "active" do
        allocate_active(group, rooms, funding, recorded_cash, issuance_order)
      else
        allocate_settled(group, rooms, funding, payments, recorded_cash)
      end
    end
  end

  defp price_rooms(group) do
    nights = Date.diff(date(group["departure_on"]), date(group["arrival_on"]))

    rows("SELECT * FROM rooms WHERE group_id = ? ORDER BY position", [group["group_id"]])
    |> Enum.map(fn room ->
      lodging = room["nightly_rate_cents"] * nights
      due = if group["rate_plan"] == "flexible", do: div(lodging * 20 + 50, 100), else: lodging

      query(
        "UPDATE rooms SET status = ?, lodging_total_cents = ?, deposit_due_cents = ? WHERE id = ?",
        [group["status"], lodging, due, room["id"]]
      )

      Map.put(room, "due", due)
    end)
  end

  defp allocate_active(group, rooms, records, recorded_cash, issuance_order) do
    # The original allocation ID is the first-consumption order, which can differ
    # from expiry order when an earlier-expiring lot was issued later.
    credits =
      rows(
        """
        SELECT allocation.*, lot.expires_on, lot.source_operation_id
        FROM credit_allocations AS allocation
        JOIN credit_lots AS lot ON lot.id = allocation.credit_lot_id
        WHERE allocation.group_id = ? ORDER BY allocation.id
        """,
        [group["group_id"]]
      )

    recorded_credit =
      records |> Enum.filter(&(&1["type"] == "apply_hotel_credit")) |> funding_total()

    legacy_cash = group["deposit_paid_cents"] - group["credit_paid_cents"] - recorded_cash
    legacy_credit = group["credit_paid_cents"] - recorded_credit
    allocate(rooms, legacy_cash, nil, nil, "held")
    credits = consume_credit(rooms, credits, legacy_credit)

    Enum.reduce(records, credits, fn record, credits ->
      case record["type"] do
        "record_cash_payment" ->
          allocate(rooms, record["result"]["amount_cents"], record["operation_id"], nil, "held")
          credits

        "apply_hotel_credit" ->
          allocate_recorded_credit(rooms, credits, record, issuance_order)

        _ ->
          credits
      end
    end)
  end

  defp allocate_recorded_credit(rooms, credits, record, issuance_order) do
    {eligible, unavailable} =
      Enum.split_with(credits, fn credit ->
        credit["expires_on"] >= record["payload"]["occurred_on"] and
          Map.get(issuance_order, credit["source_operation_id"], 0) < record["id"]
      end)

    eligible =
      Enum.sort_by(eligible, &{&1["expires_on"], &1["source_operation_id"], &1["credit_lot_id"]})

    consume_credit(rooms, eligible, record["result"]["amount_cents"]) ++ unavailable
  end

  defp allocate_settled(group, rooms, records, payments, recorded_cash) do
    disposition =
      cond do
        group["cash_converted_to_credit_cents"] > 0 -> "converted_to_credit"
        group["cash_refunded_cents"] > 0 -> "refunded"
        true -> "retained"
      end

    total =
      group["cash_refunded_cents"] + group["cash_retained_cents"] +
        group["cash_converted_to_credit_cents"]

    legacy = total - recorded_cash

    contributions = [
      {nil, legacy} | Enum.map(payments, &{&1["operation_id"], &1["result"]["amount_cents"]})
    ]

    for {payment, amount} <- contributions, do: allocate(rooms, amount, payment, nil, disposition)

    if disposition == "converted_to_credit" do
      cancellation = Enum.find(records, &(&1["type"] == "cancel_group"))

      if cancellation do
        for lot <-
              rows("SELECT * FROM credit_lots WHERE source_operation_id = ?", [
                cancellation["operation_id"]
              ]) do
          backfill_entitlements(lot, contributions)
        end
      end
    end

    query("UPDATE groups SET lodging_total_cents = 0 WHERE group_id = ?", [group["group_id"]])
  end

  defp backfill_entitlements(lot, contributions) do
    Enum.reduce(contributions, 0, fn {payment, amount}, running ->
      query(
        "INSERT INTO credit_entitlements (credit_lot_id, payment_operation_id, amount_cents) VALUES (?, ?, ?)",
        [lot["id"], payment, bonus(running + amount) - bonus(running)]
      )

      running + amount
    end)
  end

  defp funding_total(records),
    do: records |> Enum.map(& &1["result"]["amount_cents"]) |> Enum.sum()

  defp consume_credit(rooms, credits, amount) do
    {credits, 0} =
      Enum.map_reduce(credits, amount, fn credit, needed ->
        used = min(needed, credit["amount_cents"])
        allocate(rooms, used, nil, credit["credit_lot_id"], "held")
        {Map.update!(credit, "amount_cents", &(&1 - used)), needed - used}
      end)

    credits
  end

  defp allocate(_rooms, 0, _payment, _lot, _disposition), do: :ok

  defp allocate(rooms, amount, payment, lot, disposition) when amount > 0 do
    0 =
      Enum.reduce(rooms, amount, fn room, needed ->
        [[paid]] =
          query("SELECT COALESCE(SUM(amount_cents), 0) FROM room_allocations WHERE room_id = ?", [
            room["id"]
          ]).rows

        used = min(needed, max(room["due"] - paid, 0))

        if used > 0,
          do:
            query(
              "INSERT INTO room_allocations (room_id, payment_operation_id, credit_lot_id, amount_cents, disposition) VALUES (?, ?, ?, ?, ?)",
              [room["id"], payment, lot, used, disposition]
            )

        needed - used
      end)
  end

  defp bonus(cents), do: cents + div(cents * 10 + 50, 100)
  defp date(value), do: Date.from_iso8601!(value)
  defp query(sql, params), do: repo().query!(sql, params, log: false)

  defp rows(sql, params \\ []) do
    result = query(sql, params)
    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:room_allocations)
    alter table(:credit_lots), do: remove(:unrecovered_clawback_cents)

    alter table(:groups) do
      remove :cash_reduced_cents
      remove :cash_charged_back_cents
    end

    alter table(:rooms) do
      remove :status
      remove :lodging_total_cents
      remove :deposit_due_cents
    end
  end
end
