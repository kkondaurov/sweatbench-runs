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

    create table(:cash_allocations) do
      add :group_id, references(:groups, column: :group_id, type: :string), null: false
      add :room_id, :string
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
      add :disposition, :string, null: false
    end

    create index(:cash_allocations, [:group_id, :disposition])
    create index(:cash_allocations, [:payment_operation_id])

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots), null: false
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
    end

    create index(:credit_entitlements, [:payment_operation_id])
    flush()
    backfill()
  end

  # Keep upgrade logic independent of application schemas and future accounting changes.
  defp rows(sql, params \\ []) do
    result = repo().query!(sql, params)
    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end

  defp backfill do
    operations =
      rows("SELECT * FROM operations ORDER BY id")
      |> Enum.map(fn op ->
        %{
          id: op["operation_id"],
          submission: Jason.decode!(op["submission"]),
          result: Jason.decode!(op["result"])
        }
      end)

    for group <- rows("SELECT * FROM groups") do
      funding =
        Enum.filter(operations, fn op ->
          op.result["status"] == "applied" and op.result["group_id"] == group["group_id"] and
            op.submission["type"] in ~w(record_cash_payment apply_hotel_credit)
        end)

      rooms = price_rooms(group)

      if group["status"] == "active" do
        backfill_active(group, rooms, funding)
      else
        backfill_settled(group, rooms, funding, operations)
      end
    end
  end

  defp price_rooms(group) do
    nights =
      Date.diff(
        Date.from_iso8601!(group["departure_on"]),
        Date.from_iso8601!(group["arrival_on"])
      )

    Enum.map(Jason.decode!(group["rooms"]), fn encoded_room ->
      # Ecto stores array-of-map elements as JSON strings; older imports may use objects.
      room = if is_binary(encoded_room), do: Jason.decode!(encoded_room), else: encoded_room
      lodging = if group["status"] == "active", do: nights * room["nightly_rate_cents"], else: 0
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

  defp backfill_active(group, rooms, funding) do
    credits =
      rows("SELECT * FROM credit_allocations WHERE group_id = ? ORDER BY id", [group["group_id"]])

    repo().query!("DELETE FROM credit_allocations WHERE group_id = ?", [group["group_id"]])
    recorded_cash = sum_funding(funding, "record_cash_payment")
    recorded_credit = sum_funding(funding, "apply_hotel_credit")
    rooms = allocate(group, rooms, group["cash_paid_cents"] - recorded_cash, :cash, nil, nil)

    {rooms, credits} =
      allocate_credit(group, rooms, credits, group["credit_paid_cents"] - recorded_credit, nil)

    {rooms, []} =
      Enum.reduce(funding, {rooms, credits}, fn op, {rooms, credits} ->
        if op.submission["type"] == "record_cash_payment" do
          {allocate(group, rooms, op.result["amount_cents"], :cash, op.id, nil), credits}
        else
          allocate_credit(group, rooms, credits, op.result["amount_cents"], op.id)
        end
      end)

    save_rooms(group, rooms)
  end

  defp sum_funding(funding, type) do
    funding
    |> Enum.filter(&(&1.submission["type"] == type))
    |> Enum.map(& &1.result["amount_cents"])
    |> Enum.sum()
  end

  defp allocate_credit(_group, rooms, credits, 0, _op), do: {rooms, credits}

  defp allocate_credit(group, rooms, [credit | rest], amount, op) do
    used = min(credit["amount_cents"], amount)
    rooms = allocate(group, rooms, used, :credit, op, credit["credit_lot_id"])

    rest =
      if used == credit["amount_cents"],
        do: rest,
        else: [Map.put(credit, "amount_cents", credit["amount_cents"] - used) | rest]

    allocate_credit(group, rooms, rest, amount - used, op)
  end

  defp allocate(group, rooms, amount, kind, op, lot) do
    {rooms, 0} =
      Enum.map_reduce(rooms, amount, fn room, left ->
        used =
          min(
            left,
            room["deposit_due_cents"] - room["cash_paid_cents"] - room["credit_paid_cents"]
          )

        if used > 0 do
          if kind == :cash do
            insert_cash(group, room["room_id"], op, used, "held")
          else
            repo().query!(
              "INSERT INTO credit_allocations (group_id, room_id, operation_id, credit_lot_id, amount_cents) VALUES (?, ?, ?, ?, ?)",
              [group["group_id"], room["room_id"], op, lot, used]
            )
          end
        end

        key = if kind == :cash, do: "cash_paid_cents", else: "credit_paid_cents"
        {Map.update!(room, key, &(&1 + used)), left - used}
      end)

    rooms
  end

  defp insert_cash(group, room, op, amount, disposition) do
    repo().query!(
      "INSERT INTO cash_allocations (group_id, room_id, payment_operation_id, amount_cents, disposition) VALUES (?, ?, ?, ?, ?)",
      [group["group_id"], room, op, amount, disposition]
    )
  end

  defp backfill_settled(group, rooms, funding, operations) do
    disposition =
      cond do
        group["cash_converted_to_credit_cents"] > 0 -> "converted_to_credit"
        group["cash_retained_cents"] > 0 -> "retained"
        true -> "refunded"
      end

    total =
      group["cash_converted_to_credit_cents"] + group["cash_retained_cents"] +
        group["cash_refunded_cents"]

    cash = Enum.filter(funding, &(&1.submission["type"] == "record_cash_payment"))

    blocks =
      [{nil, total - sum_funding(cash, "record_cash_payment")}] ++
        Enum.map(cash, &{&1.id, &1.result["amount_cents"]})

    for {id, amount} <- blocks, amount > 0, do: insert_cash(group, nil, id, amount, disposition)

    if disposition == "converted_to_credit" do
      cancellation =
        Enum.find(operations, fn op ->
          op.submission["type"] == "cancel_group" and op.result["status"] == "applied" and
            op.result["group_id"] == group["group_id"]
        end)

      if cancellation do
        for lot <-
              rows("SELECT id FROM credit_lots WHERE source_operation_id = ?", [cancellation.id]) do
          Enum.reduce(blocks, 0, fn {id, amount}, preceding ->
            through = preceding + amount

            if amount > 0 do
              entitlement = bonus(through) - bonus(preceding)

              repo().query!(
                "INSERT INTO credit_entitlements (credit_lot_id, payment_operation_id, amount_cents) VALUES (?, ?, ?)",
                [lot["id"], id, entitlement]
              )
            end

            through
          end)
        end
      end
    end

    save_rooms(group, rooms)
  end

  defp bonus(amount), do: amount + div(amount * 10 + 50, 100)

  defp save_rooms(group, rooms) do
    lodging = Enum.sum(Enum.map(rooms, & &1["lodging_total_cents"]))

    repo().query!("UPDATE groups SET rooms = ?, lodging_total_cents = ? WHERE group_id = ?", [
      Jason.encode!(rooms),
      lodging,
      group["group_id"]
    ])
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:cash_allocations)

    alter table(:credit_allocations) do
      remove :room_id
      remove :operation_id
    end

    alter table(:credit_lots), do: remove(:unrecovered_clawback_cents)

    alter table(:groups) do
      remove :cash_reduced_cents
      remove :cash_charged_back_cents
    end
  end
end
