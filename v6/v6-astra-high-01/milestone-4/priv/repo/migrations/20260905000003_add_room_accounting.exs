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

    create table(:funding_allocations) do
      add :group_id, references(:groups, column: :group_id, type: :string), null: false
      add :room_id, :string
      # The audit record is inserted after domain effects, in the same transaction.
      add :payment_operation_id, :string
      add :credit_lot_id, references(:credit_lots)
      add :kind, :string, null: false
      add :disposition, :string, null: false
      add :amount_cents, :integer, null: false
      add :converted_lot_id, references(:credit_lots)
    end

    create index(:funding_allocations, [:group_id, :disposition])
    create index(:funding_allocations, [:payment_operation_id, :disposition])

    create table(:credit_entitlements) do
      add :payment_operation_id, :string, null: false
      add :credit_lot_id, references(:credit_lots), null: false
      add :amount_cents, :integer, null: false
    end

    create unique_index(:credit_entitlements, [:payment_operation_id, :credit_lot_id])
    flush()

    # Frozen migration logic: no dependency on evolving application schemas.
    records_by_group =
      rows("SELECT * FROM operations ORDER BY id")
      |> Enum.map(fn r ->
        r
        |> Map.put("result", Jason.decode!(r["result"]))
        |> Map.put("submission", Jason.decode!(r["submission"]))
      end)
      |> Enum.filter(&(&1["result"]["status"] == "applied"))
      |> Enum.group_by(& &1["result"]["group_id"])

    for group <- rows("SELECT * FROM groups ORDER BY group_id") do
      backfill(group, Map.get(records_by_group, group["group_id"], []))
    end
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:funding_allocations)
    alter table(:credit_lots), do: remove(:unrecovered_clawback_cents)

    alter table(:groups) do
      remove :cash_reduced_cents
      remove :cash_charged_back_cents
    end
  end

  defp backfill(g, records) do
    nights = Date.diff(Date.from_iso8601!(g["departure_on"]), Date.from_iso8601!(g["arrival_on"]))

    rooms =
      for room <- Jason.decode!(g["rooms"]) do
        lodging = nights * room["nightly_rate_cents"]
        due = if g["rate_plan"] == "flexible", do: div(lodging * 20 + 50, 100), else: lodging

        Map.merge(room, %{
          "status" => g["status"],
          "lodging_total_cents" => lodging,
          "deposit_due_cents" => due,
          "cash_paid_cents" => 0,
          "credit_paid_cents" => 0
        })
      end

    funding = Enum.filter(records, &(&1["type"] in ["record_cash_payment", "apply_hotel_credit"]))
    cash_records = Enum.filter(funding, &(&1["type"] == "record_cash_payment"))

    cash_total =
      if g["status"] == "active",
        do: g["cash_paid_cents"],
        else:
          g["cash_refunded_cents"] + g["cash_retained_cents"] +
            g["cash_converted_to_credit_cents"]

    legacy_cash = cash_total - Enum.sum(Enum.map(cash_records, & &1["result"]["amount_cents"]))

    rooms =
      if g["status"] == "active" do
        lots =
          rows(
            "SELECT a.*, l.expires_on, l.source_operation_id, o.id AS source_commit_id
             FROM credit_allocations a JOIN credit_lots l ON l.id = a.credit_lot_id
             LEFT JOIN operations o ON o.operation_id = l.source_operation_id
               AND o.type = 'cancel_group' AND json_extract(o.result, '$.status') = 'applied'
             WHERE a.group_id = ? ORDER BY a.id",
            [g["group_id"]]
          )

        legacy_credit =
          g["credit_paid_cents"] -
            Enum.sum(
              for r <- funding, r["type"] == "apply_hotel_credit", do: r["result"]["amount_cents"]
            )

        rooms = allocate(g, rooms, "cash", legacy_cash, nil, nil)

        {rooms, lots} =
          allocate_credit(g, rooms, lots, legacy_credit, &is_nil(&1["source_commit_id"]))

        {rooms, _} =
          Enum.reduce(funding, {rooms, lots}, fn r, {rs, ls} ->
            amount = r["result"]["amount_cents"]

            if r["type"] == "record_cash_payment" do
              {allocate(g, rs, "cash", amount, r["operation_id"], nil), ls}
            else
              # Existing group/lot allocations preserve first consumption order for
              # the senior block. Later applications use the original expiry rule.
              ls = Enum.sort_by(ls, &{&1["expires_on"], &1["source_operation_id"]})

              allocate_credit(g, rs, ls, amount, fn lot ->
                (is_nil(lot["source_commit_id"]) or lot["source_commit_id"] < r["id"]) and
                  lot["expires_on"] >= r["submission"]["occurred_on"]
              end)
            end
          end)

        rooms
      else
        disposition =
          cond do
            g["cash_converted_to_credit_cents"] > 0 -> "converted_to_credit"
            g["cash_retained_cents"] > 0 -> "retained"
            true -> "refunded"
          end

        cancellation = Enum.find(records, &(&1["type"] == "cancel_group"))

        lot =
          if disposition == "converted_to_credit" and cancellation,
            do:
              List.first(
                rows("SELECT id FROM credit_lots WHERE source_operation_id = ?", [
                  cancellation["operation_id"]
                ])
              )

        lot_id = if lot, do: lot["id"]
        if legacy_cash > 0, do: insert(g, nil, "cash", legacy_cash, nil, nil, disposition, lot_id)

        Enum.reduce(cash_records, legacy_cash, fn r, running ->
          amount = r["result"]["amount_cents"]
          insert(g, nil, "cash", amount, r["operation_id"], nil, disposition, lot_id)

          if lot_id do
            repo().query!(
              "INSERT INTO credit_entitlements (payment_operation_id, credit_lot_id, amount_cents) VALUES (?, ?, ?)",
              [r["operation_id"], lot_id, bonus(running + amount) - bonus(running)]
            )
          end

          running + amount
        end)

        rooms
      end

    lodging = if g["status"] == "active", do: g["lodging_total_cents"], else: 0

    repo().query!("UPDATE groups SET rooms = ?, lodging_total_cents = ? WHERE group_id = ?", [
      Jason.encode!(rooms),
      lodging,
      g["group_id"]
    ])
  end

  defp allocate_credit(g, rooms, lots, amount, eligible) do
    if amount < 0, do: raise("recorded credit exceeds aggregate credit")

    {rooms, lots, left} =
      Enum.reduce(lots, {rooms, [], amount}, fn lot, {rs, ls, needed} ->
        used = if eligible.(lot), do: min(needed, lot["amount_cents"]), else: 0
        rs = allocate(g, rs, "credit", used, nil, lot["credit_lot_id"])
        {rs, [Map.put(lot, "amount_cents", lot["amount_cents"] - used) | ls], needed - used}
      end)

    if left != 0, do: raise("cannot reconstruct credit funding")
    {rooms, Enum.reverse(lots)}
  end

  defp allocate(g, rooms, kind, amount, payment, lot) do
    if amount < 0, do: raise("recorded funding exceeds aggregate funding")

    {rooms, left} =
      Enum.map_reduce(rooms, amount, fn room, needed ->
        used =
          min(
            needed,
            room["deposit_due_cents"] - room["cash_paid_cents"] - room["credit_paid_cents"]
          )

        if used > 0, do: insert(g, room["room_id"], kind, used, payment, lot, "held", nil)
        field = kind <> "_paid_cents"
        {Map.update!(room, field, &(&1 + used)), needed - used}
      end)

    if left != 0, do: raise("cannot reconstruct room funding")
    rooms
  end

  defp insert(g, room, kind, amount, payment, lot, disposition, converted_lot) do
    repo().query!(
      "INSERT INTO funding_allocations (group_id, room_id, kind, amount_cents, payment_operation_id, credit_lot_id, disposition, converted_lot_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [g["group_id"], room, kind, amount, payment, lot, disposition, converted_lot]
    )
  end

  defp bonus(amount), do: amount + div(amount * 10 + 50, 100)

  defp rows(sql, params \\ []) do
    %{columns: columns, rows: rows} = repo().query!(sql, params)
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end
end
