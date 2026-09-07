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
    end

    create table(:cash_allocations) do
      add :group_id, references(:groups, column: :group_id, type: :string), null: false
      add :room_id, :string, null: false
      # The receipt is inserted after its domain writes in the same transaction.
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
      add :disposition, :string, null: false
    end

    create index(:cash_allocations, [:group_id])
    create index(:cash_allocations, [:payment_operation_id])

    create table(:credit_entitlements) do
      add :payment_operation_id, :string
      add :credit_lot_id, references(:credit_lots), null: false
      add :amount_cents, :integer, null: false
    end

    create index(:credit_entitlements, [:payment_operation_id])
    execute(&backfill/0)
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:cash_allocations)
    alter table(:credit_allocations), do: remove(:room_id)
    alter table(:credit_lots), do: remove(:unrecovered_clawback_cents)

    alter table(:groups) do
      remove :cash_reduced_cents
      remove :cash_charged_back_cents
    end
  end

  # Keep the upgrade independent of application schemas, which will evolve.
  defp backfill do
    records_by_group =
      rows("SELECT * FROM operations ORDER BY id")
      |> Enum.map(&Map.update!(&1, "result", fn result -> Jason.decode!(result) end))
      |> Enum.filter(&(&1["result"]["status"] == "applied"))
      |> Enum.group_by(& &1["result"]["group_id"])

    for group <- rows("SELECT * FROM groups") do
      backfill_group(group, Map.get(records_by_group, group["group_id"], []))
    end
  end

  defp backfill_group(group, records) do
    blocks = funding_blocks(group, records)
    disposition = disposition(group)
    query("DELETE FROM credit_allocations WHERE group_id = ?", [group["group_id"]])

    rooms =
      Enum.reduce(blocks, price_rooms(group), fn block, rooms ->
        allocate_block(group["group_id"], rooms, block, disposition)
      end)

    rooms = if group["status"] == "active", do: rooms, else: Enum.map(rooms, &clear_room/1)
    lodging = rooms |> Enum.map(& &1["lodging_total_cents"]) |> Enum.sum()

    query(
      "UPDATE groups SET rooms = ?, lodging_total_cents = ? WHERE group_id = ?",
      [Jason.encode!(rooms), lodging, group["group_id"]]
    )

    if disposition == "converted_to_credit", do: backfill_entitlements(blocks, records)
  end

  # Before receipts existed there was no interleaving evidence. Treat that cash
  # and credit as one senior block, then replay recorded funding by commit ID.
  defp funding_blocks(group, records) do
    funding = Enum.filter(records, &(&1["type"] in ["record_cash_payment", "apply_hotel_credit"]))

    cash_total =
      Enum.sum(
        for field <-
              ~w(cash_paid_cents cash_refunded_cents cash_retained_cents cash_converted_to_credit_cents),
            do: group[field]
      )

    senior_cash = cash_total - recorded_amount(funding, "record_cash_payment")

    credits =
      rows("SELECT * FROM credit_allocations WHERE group_id = ? ORDER BY id", [group["group_id"]])
      |> Enum.map(&{&1["credit_lot_id"], &1["amount_cents"]})

    active? = group["status"] == "active"

    senior_credit =
      if active?,
        do:
          Enum.sum(Enum.map(credits, &elem(&1, 1))) -
            recorded_amount(funding, "apply_hotel_credit"),
        else: 0

    {senior_lots, credits} = take_credit(credits, senior_credit)

    {recorded_blocks, []} =
      Enum.flat_map_reduce(funding, credits, fn record, credits ->
        recorded_blocks(record, credits, active?)
      end)

    [{:cash, nil, senior_cash}] ++ credit_blocks(senior_lots) ++ recorded_blocks
  end

  defp recorded_amount(records, type) do
    records
    |> Enum.filter(&(&1["type"] == type))
    |> Enum.map(& &1["result"]["amount_cents"])
    |> Enum.sum()
  end

  defp recorded_blocks(%{"type" => "record_cash_payment"} = record, credits, _active?) do
    {[{:cash, record["operation_id"], record["result"]["amount_cents"]}], credits}
  end

  defp recorded_blocks(record, credits, true) do
    {lots, credits} = take_credit(credits, record["result"]["amount_cents"])
    {credit_blocks(lots), credits}
  end

  # Earlier full cancellations already restored or consumed these redemptions.
  defp recorded_blocks(_record, credits, false), do: {[], credits}

  defp credit_blocks(lots), do: Enum.map(lots, fn {id, amount} -> {:credit, id, amount} end)

  defp price_rooms(group) do
    nights =
      Date.diff(
        Date.from_iso8601!(group["departure_on"]),
        Date.from_iso8601!(group["arrival_on"])
      )

    Jason.decode!(group["rooms"])
    |> Enum.map(fn room ->
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

  defp disposition(group) do
    cond do
      group["status"] == "active" -> "held"
      group["cash_refunded_cents"] > 0 -> "refunded"
      group["cash_retained_cents"] > 0 -> "retained"
      true -> "converted_to_credit"
    end
  end

  defp allocate_block(group_id, rooms, {kind, source, amount}, disposition) do
    {rooms, 0} =
      Enum.map_reduce(rooms, amount, fn room, remaining ->
        capacity = room["deposit_due_cents"] - room["cash_paid_cents"] - room["credit_paid_cents"]
        allocated = min(remaining, capacity)

        if allocated > 0,
          do: insert_allocation(kind, group_id, room["room_id"], source, allocated, disposition)

        field = if kind == :cash, do: "cash_paid_cents", else: "credit_paid_cents"
        {Map.update!(room, field, &(&1 + allocated)), remaining - allocated}
      end)

    rooms
  end

  defp insert_allocation(:cash, group_id, room_id, payment_id, amount, disposition) do
    query(
      """
      INSERT INTO cash_allocations (group_id, room_id, payment_operation_id, amount_cents, disposition)
      VALUES (?, ?, ?, ?, ?)
      """,
      [group_id, room_id, payment_id, amount, disposition]
    )
  end

  defp insert_allocation(:credit, group_id, room_id, lot_id, amount, _disposition) do
    query(
      """
      INSERT INTO credit_allocations (group_id, room_id, credit_lot_id, amount_cents)
      VALUES (?, ?, ?, ?)
      """,
      [group_id, room_id, lot_id, amount]
    )
  end

  defp clear_room(room) do
    Map.merge(room, %{
      "lodging_total_cents" => 0,
      "deposit_due_cents" => 0,
      "cash_paid_cents" => 0,
      "credit_paid_cents" => 0
    })
  end

  defp backfill_entitlements(blocks, records) do
    cancellation =
      Enum.find(
        records,
        &(&1["type"] == "cancel_group" and &1["result"]["credit_issued_cents"] > 0)
      )

    if cancellation do
      [lot] =
        rows("SELECT id FROM credit_lots WHERE source_operation_id = ?", [
          cancellation["operation_id"]
        ])

      blocks
      |> Enum.filter(&(elem(&1, 0) == :cash))
      |> Enum.reduce(0, fn {:cash, payment_id, amount}, running ->
        entitlement = bonus(running + amount) - bonus(running)

        if entitlement > 0 do
          query(
            "INSERT INTO credit_entitlements (payment_operation_id, credit_lot_id, amount_cents) VALUES (?, ?, ?)",
            [payment_id, lot["id"], entitlement]
          )
        end

        running + amount
      end)
    end
  end

  defp take_credit(credits, 0), do: {[], credits}

  defp take_credit([{id, amount} | rest], needed) when needed > 0 do
    taken = min(amount, needed)
    remaining = if taken == amount, do: rest, else: [{id, amount - taken} | rest]
    {next, remaining} = take_credit(remaining, needed - taken)
    {[{id, taken} | next], remaining}
  end

  defp bonus(cash), do: cash + div(cash + 5, 10)
  defp query(sql, params), do: repo().query!(sql, params)

  defp rows(sql, params \\ []) do
    result = query(sql, params)
    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end
end
