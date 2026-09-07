defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    create table(:cash_allocations) do
      add :group_id, references(:groups, column: :group_id, type: :text), null: false
      add :room_id, :text
      add :payment_operation_id, :text
      add :amount_cents, :integer, null: false
      add :disposition, :text, null: false
    end

    create index(:cash_allocations, [:group_id])
    create index(:cash_allocations, [:payment_operation_id])

    alter table(:credit_allocations) do
      add :room_id, :text
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:credit_entitlements) do
      add :payment_operation_id, :text
      add :credit_lot_id, references(:credit_lots), null: false
      add :amount_cents, :integer, null: false
    end

    create index(:credit_entitlements, [:payment_operation_id])
    flush()

    # Keep the upgrade independent of runtime schemas. Before this release a
    # group was either wholly active or wholly settled, so active credit rows
    # retain their original consumption order and all recorded funding survives.
    entries =
      rows("SELECT * FROM operations ORDER BY id")
      |> Enum.map(&Map.update!(&1, "result", fn value -> decode(value) end))

    for group <- rows("SELECT * FROM groups") do
      funding =
        Enum.filter(
          entries,
          &(&1["result"]["status"] == "applied" and
              &1["result"]["group_id"] == group["group_id"] and
              &1["type"] in ["record_cash_payment", "apply_hotel_credit"])
        )

      migrate_group(group, funding, entries)
    end
  end

  defp migrate_group(group, funding, entries) do
    id = group["group_id"]
    active? = group["status"] == "active"

    nights =
      Date.diff(
        Date.from_iso8601!(group["departure_on"]),
        Date.from_iso8601!(group["arrival_on"])
      )

    rooms =
      Enum.map(decode(group["rooms"]), fn room ->
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

    cash =
      if active?,
        do: group["deposit_paid_cents"] - group["credit_paid_cents"],
        else:
          group["refunded_cents"] + group["retained_cents"] + group["converted_to_credit_cents"]

    payments = Enum.filter(funding, &(&1["type"] == "record_cash_payment"))
    legacy_cash = cash - Enum.sum(Enum.map(payments, & &1["result"]["amount_cents"]))

    rooms =
      if active? do
        migrate_active_funding(id, rooms, funding, legacy_cash)
      else
        migrate_settlement(group, payments, legacy_cash, entries)
        rooms
      end

    repo().query!("UPDATE groups SET rooms = ? WHERE group_id = ?", [Jason.encode!(rooms), id])
  end

  defp migrate_active_funding(id, rooms, funding, legacy_cash) do
    credits = rows("SELECT * FROM credit_allocations WHERE group_id = ? ORDER BY id", [id])

    recorded_credit =
      funding
      |> Enum.filter(&(&1["type"] == "apply_hotel_credit"))
      |> Enum.map(& &1["result"]["amount_cents"])
      |> Enum.sum()

    legacy_credit = Enum.sum(Enum.map(credits, & &1["amount_cents"])) - recorded_credit
    repo().query!("DELETE FROM credit_allocations WHERE group_id = ?", [id])
    rooms = allocate(rooms, legacy_cash, id, nil, nil)
    {rooms, credits} = allocate_credit(rooms, credits, legacy_credit, id)

    {rooms, []} =
      Enum.reduce(funding, {rooms, credits}, fn entry, {rooms, credits} ->
        amount = entry["result"]["amount_cents"]

        if entry["type"] == "record_cash_payment" do
          {allocate(rooms, amount, id, entry["operation_id"], nil), credits}
        else
          allocate_credit(rooms, credits, amount, id)
        end
      end)

    rooms
  end

  defp migrate_settlement(group, payments, legacy_cash, entries) do
    id = group["group_id"]

    disposition =
      cond do
        group["converted_to_credit_cents"] > 0 -> "converted_to_credit"
        group["refunded_cents"] > 0 -> "refunded"
        true -> "retained"
      end

    portions =
      [{nil, legacy_cash}] ++
        Enum.map(payments, &{&1["operation_id"], &1["result"]["amount_cents"]})

    for {payment, amount} <- portions,
        amount > 0,
        do: insert_cash(id, nil, payment, amount, disposition)

    if disposition == "converted_to_credit", do: migrate_entitlements(id, portions, entries)
    repo().query!("UPDATE groups SET lodging_total_cents = 0 WHERE group_id = ?", [id])
  end

  defp migrate_entitlements(group_id, portions, entries) do
    cancellation =
      Enum.find(
        entries,
        &(&1["type"] == "cancel_group" and
            &1["result"]["group_id"] == group_id and &1["result"]["status"] == "applied")
      )

    # A pre-journal cancellation has no attributable payments to claw back.
    if cancellation do
      for lot <-
            rows("SELECT id FROM credit_lots WHERE source_operation_id = ?", [
              cancellation["operation_id"]
            ]) do
        Enum.reduce(portions, 0, fn {payment, amount}, prior ->
          repo().query!(
            "INSERT INTO credit_entitlements (payment_operation_id, credit_lot_id, amount_cents) VALUES (?, ?, ?)",
            [payment, lot["id"], bonus(prior + amount) - bonus(prior)]
          )

          prior + amount
        end)
      end
    end
  end

  defp allocate_credit(rooms, credits, 0, _id), do: {rooms, credits}

  defp allocate_credit(rooms, [credit | rest], amount, id) do
    used = min(amount, credit["amount_cents"])
    rooms = allocate(rooms, used, id, nil, credit["credit_lot_id"])

    rest =
      if used == credit["amount_cents"],
        do: rest,
        else: [Map.update!(credit, "amount_cents", &(&1 - used)) | rest]

    allocate_credit(rooms, rest, amount - used, id)
  end

  defp allocate(rooms, amount, id, payment, lot) do
    {rooms, remaining} =
      Enum.map_reduce(rooms, amount, fn room, needed ->
        used =
          min(
            needed,
            room["deposit_due_cents"] - room["cash_paid_cents"] - room["credit_paid_cents"]
          )

        if used > 0, do: insert_funding(id, room["room_id"], payment, lot, used)
        key = if lot, do: "credit_paid_cents", else: "cash_paid_cents"
        {Map.update!(room, key, &(&1 + used)), needed - used}
      end)

    # Preserve malformed historical accounts with no room inventory as well;
    # valid reservations always consume the entire amount into their rooms.
    if remaining > 0, do: insert_funding(id, nil, payment, lot, remaining)
    rooms
  end

  defp insert_funding(id, room, payment, nil, amount),
    do: insert_cash(id, room, payment, amount, "held")

  defp insert_funding(id, room, _payment, lot, amount) do
    repo().query!(
      "INSERT INTO credit_allocations (group_id, room_id, credit_lot_id, amount_cents) VALUES (?, ?, ?, ?)",
      [id, room, lot, amount]
    )
  end

  defp insert_cash(id, room, payment, amount, disposition) do
    repo().query!(
      "INSERT INTO cash_allocations (group_id, room_id, payment_operation_id, amount_cents, disposition) VALUES (?, ?, ?, ?, ?)",
      [id, room, payment, amount, disposition]
    )
  end

  defp bonus(amount), do: amount + div(amount * 10 + 50, 100)
  defp decode(value) when is_binary(value), do: Jason.decode!(value)
  defp decode(value), do: value

  defp rows(sql, params \\ []) do
    %{columns: columns, rows: rows} = repo().query!(sql, params)
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end

  def down do
    drop table(:credit_entitlements)
    alter table(:credit_lots), do: remove(:unrecovered_clawback_cents)
    alter table(:credit_allocations), do: remove(:room_id)
    drop table(:cash_allocations)
  end
end
