defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
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

    # Each partial cancellation can now issue its own lot.
    drop unique_index(:credit_lots, [:source_group_id])
    create index(:credit_lots, [:source_group_id])

    create table(:room_allocations) do
      add :group_id, references(:groups, column: :group_id, type: :string), null: false
      add :room_id, references(:rooms), null: false
      # The journal row commits after domain writes in the same transaction.
      add :funding_operation_id, :string
      add :credit_lot_id, references(:credit_lots)

      for field <-
            ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)a do
        add field, :integer,
          null: false,
          default: 0,
          check: %{name: "room_allocation_#{field}_nonnegative", expr: "#{field} >= 0"}
      end
    end

    create index(:room_allocations, [:group_id, :room_id])
    create index(:room_allocations, [:funding_operation_id])
    create index(:room_allocations, [:credit_lot_id])

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots), null: false
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
    end

    create unique_index(:credit_entitlements, [:credit_lot_id, :payment_operation_id])
    create index(:credit_entitlements, [:payment_operation_id])
    flush()

    # Use only this migration's SQL and integer arithmetic, independent of future schemas.
    operations =
      rows("SELECT * FROM operations ORDER BY id")
      |> Enum.map(fn op ->
        %{op | "payload" => decode(op["payload"]), "result" => decode(op["result"])}
      end)

    for group <-
          rows(
            "SELECT group_id, arrival_on, departure_on, rate_plan, status, deposit_paid_cents, credit_paid_cents, cash_refunded_cents, cash_retained_cents, cash_converted_to_credit_cents FROM groups ORDER BY group_id"
          ) do
      backfill_group(group, operations)
    end
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:room_allocations)
    drop index(:credit_lots, [:source_group_id])
    create unique_index(:credit_lots, [:source_group_id])
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

  defp backfill_group(group, operations) do
    id = group["group_id"]

    nights =
      Date.diff(
        Date.from_iso8601!(group["departure_on"]),
        Date.from_iso8601!(group["arrival_on"])
      )

    rooms =
      for room <-
            rows(
              "SELECT id, nightly_rate_cents FROM rooms WHERE group_id = ? ORDER BY position",
              [id]
            ) do
        lodging = nights * room["nightly_rate_cents"]
        due = if group["rate_plan"] == "flexible", do: div(lodging * 20 + 50, 100), else: lodging

        repo().query!(
          "UPDATE rooms SET status = ?, lodging_total_cents = ?, deposit_due_cents = ? WHERE id = ?",
          [
            group["status"],
            lodging,
            if(group["status"] == "active", do: due, else: 0),
            room["id"]
          ]
        )

        {room["id"], due}
      end

    if group["status"] == "cancelled" do
      repo().query!("UPDATE groups SET lodging_total_cents = 0 WHERE group_id = ?", [id])
    end

    funding =
      Enum.filter(operations, fn op ->
        op["type"] in ~w(record_cash_payment apply_hotel_credit) and
          op["result"]["status"] == "applied" and op["result"]["group_id"] == id
      end)

    cash =
      group["deposit_paid_cents"] - group["credit_paid_cents"] +
        group["cash_refunded_cents"] + group["cash_retained_cents"] +
        group["cash_converted_to_credit_cents"]

    recorded_cash =
      funding |> Enum.filter(&(&1["type"] == "record_cash_payment")) |> total_funding()

    recorded_credit =
      funding |> Enum.filter(&(&1["type"] == "apply_hotel_credit")) |> total_funding()

    pool =
      rows(
        """
        SELECT a.credit_lot_id, a.amount_cents, l.expires_on, l.source_operation_id, coalesce(o.id, 0) AS issued_order
        FROM credit_allocations a JOIN credit_lots l ON l.id = a.credit_lot_id
        LEFT JOIN operations o ON o.operation_id = l.source_operation_id
        WHERE a.group_id = ? ORDER BY a.id
        """,
        [id]
      )

    legacy_credit = Enum.sum(Enum.map(pool, & &1["amount_cents"])) - recorded_credit
    credit = reconstruct_credit(pool, funding, legacy_credit)
    senior_cash = cash - recorded_cash
    if senior_cash < 0, do: raise("legacy cash is smaller than recorded cash")

    blocks =
      [{nil, nil, senior_cash}] ++
        credit_blocks(credit, nil) ++
        Enum.flat_map(funding, fn op ->
          if op["type"] == "record_cash_payment" do
            [{op["operation_id"], nil, op["result"]["amount_cents"]}]
          else
            credit_blocks(credit, op["operation_id"])
          end
        end)

    disposition =
      cond do
        group["status"] == "active" -> "held_cents"
        group["cash_converted_to_credit_cents"] > 0 -> "converted_to_credit_cents"
        group["cash_retained_cents"] > 0 -> "retained_cents"
        true -> "refunded_cents"
      end

    Enum.reduce(blocks, rooms, fn {operation_id, lot_id, amount}, rooms ->
      fill(rooms, amount, fn room_id, taken ->
        field = if lot_id, do: "held_cents", else: disposition
        value = if lot_id && group["status"] == "cancelled", do: 0, else: taken

        repo().query!(
          "INSERT INTO room_allocations (group_id, room_id, funding_operation_id, credit_lot_id, #{field}) VALUES (?, ?, ?, ?, ?)",
          [id, room_id, operation_id, lot_id, value]
        )
      end)
    end)

    if disposition == "converted_to_credit_cents" do
      [lot] = rows("SELECT id FROM credit_lots WHERE source_group_id = ?", [id])

      blocks
      |> Enum.filter(fn {_, lot, _} -> is_nil(lot) end)
      |> Enum.reduce(0, fn {payment_id, _, amount}, preceding ->
        if amount > 0 do
          repo().query!(
            "INSERT INTO credit_entitlements (credit_lot_id, payment_operation_id, amount_cents) VALUES (?, ?, ?)",
            [lot["id"], payment_id, bonus_value(preceding + amount) - bonus_value(preceding)]
          )
        end

        preceding + amount
      end)
    end
  end

  defp fill(rooms, amount, insert) do
    {rooms, remaining} =
      Enum.map_reduce(rooms, amount, fn {id, space}, needed ->
        taken = min(space, needed)
        if taken > 0, do: insert.(id, taken)
        {{id, space - taken}, needed - taken}
      end)

    if remaining != 0, do: raise("legacy funding exceeds room deposits")
    rooms
  end

  defp reconstruct_credit(pool, funding, legacy_amount) do
    if legacy_amount < 0, do: raise("legacy credit is smaller than recorded credit")

    senior_lots =
      pool |> Enum.filter(&(&1["issued_order"] == 0)) |> Enum.map(& &1["credit_lot_id"])

    requests =
      [{nil, legacy_amount, senior_lots}] ++
        for op <- funding, op["type"] == "apply_hotel_credit" do
          eligible =
            pool
            |> Enum.filter(
              &(&1["issued_order"] < op["id"] and &1["expires_on"] >= op["payload"]["occurred_on"])
            )
            |> Enum.sort_by(&{&1["expires_on"], &1["source_operation_id"]})
            |> Enum.map(& &1["credit_lot_id"])

          {op["operation_id"], op["result"]["amount_cents"], eligible}
        end

    preferences = Map.new(requests, fn {key, _, lots} -> {key, lots} end)
    capacity = Map.new(pool, &{&1["credit_lot_id"], &1["amount_cents"]})
    owners = requests |> Enum.map(&elem(&1, 0)) |> Enum.reverse()

    # Preserve the senior block's original consumption order, then recorded FIFO order.
    # A later application may have an expiry/issuance constraint. Residual paths reserve
    # eligible lots for it by moving earlier assignments only when direct capacity is gone.
    assigned =
      Enum.reduce(requests, %{}, fn {key, amount, _}, assigned ->
        assign_credit(key, amount, assigned, preferences, capacity, owners)
      end)

    Map.new(requests, fn {key, _, lots} ->
      {key,
       for(lot <- lots, amount = Map.get(assigned, {key, lot}, 0), amount > 0, do: {lot, amount})}
    end)
  end

  defp credit_blocks(credit, key),
    do: Enum.map(credit[key], fn {lot, amount} -> {key, lot, amount} end)

  defp assign_credit(_key, 0, assigned, _preferences, _capacity, _owners), do: assigned

  defp assign_credit(key, needed, assigned, preferences, capacity, owners) do
    queue = :queue.from_list([{{:funding, key}, [], needed}])

    {path, amount} =
      credit_path(queue, MapSet.new([{:funding, key}]), assigned, preferences, capacity, owners)

    assigned =
      Enum.reduce(path, assigned, fn {key, lot, sign}, assigned ->
        Map.update(assigned, {key, lot}, sign * amount, &(&1 + sign * amount))
      end)

    assign_credit(key, needed - amount, assigned, preferences, capacity, owners)
  end

  defp credit_path(queue, seen, assigned, preferences, capacity, owners) do
    case :queue.out(queue) do
      {:empty, _} ->
        raise("cannot reconstruct recorded hotel credit")

      {{:value, {{:funding, key}, path, limit}}, queue} ->
        neighbors = for lot <- preferences[key], do: {{:lot, lot}, [{key, lot, 1} | path], limit}
        {queue, seen} = enqueue_credit(queue, seen, neighbors)
        credit_path(queue, seen, assigned, preferences, capacity, owners)

      {{:value, {{:lot, lot}, path, limit}}, queue} ->
        used = Enum.reduce(owners, 0, &(&2 + Map.get(assigned, {&1, lot}, 0)))
        free = capacity[lot] - used

        if free > 0 do
          {path, min(limit, free)}
        else
          neighbors =
            for owner <- owners,
                held = Map.get(assigned, {owner, lot}, 0),
                held > 0,
                do: {{:funding, owner}, [{owner, lot, -1} | path], min(limit, held)}

          {queue, seen} = enqueue_credit(queue, seen, neighbors)
          credit_path(queue, seen, assigned, preferences, capacity, owners)
        end
    end
  end

  defp enqueue_credit(queue, seen, neighbors) do
    Enum.reduce(neighbors, {queue, seen}, fn {node, _, _} = entry, {queue, seen} ->
      if MapSet.member?(seen, node),
        do: {queue, seen},
        else: {:queue.in(entry, queue), MapSet.put(seen, node)}
    end)
  end

  defp total_funding(ops), do: Enum.sum(Enum.map(ops, & &1["result"]["amount_cents"]))
  defp bonus_value(cash), do: cash + div(cash * 10 + 50, 100)
  defp decode(json) when is_binary(json), do: Jason.decode!(json)
  defp decode(json), do: json

  defp rows(sql, args \\ []) do
    result = repo().query!(sql, args)
    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end
end
