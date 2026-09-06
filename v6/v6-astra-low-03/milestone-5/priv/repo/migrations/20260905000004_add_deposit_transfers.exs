defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    create table(:allocation_sequence) do
    end

    create table(:transferred_payments, primary_key: false) do
      add :payment_operation_id, :string, primary_key: true
    end

    alter table(:cash_allocations), do: add(:allocation_order, :integer, null: false, default: 0)

    alter table(:credit_allocations),
      do: add(:allocation_order, :integer, null: false, default: 0)

    flush()
    backfill()
  end

  def down do
    alter table(:cash_allocations), do: remove(:allocation_order)
    alter table(:credit_allocations), do: remove(:allocation_order)
    drop table(:transferred_payments)
    drop table(:allocation_sequence)
  end

  defp rows(sql) do
    result = repo().query!(sql)
    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end

  defp backfill do
    # Replay successful submissions against an isolated accounting model to recover
    # creation order lost by the older, separate cash and credit sequences.
    cash = rows("SELECT * FROM cash_allocations ORDER BY id")
    credit = rows("SELECT * FROM credit_allocations ORDER BY id")

    operations =
      rows("SELECT * FROM operations ORDER BY id")
      |> Enum.map(fn op ->
        Map.merge(op, %{
          "result" => Jason.decode!(op["result"]),
          "submission" => Jason.decode!(op["submission"])
        })
      end)
      |> Enum.filter(&(&1["result"]["status"] == "applied"))

    groups = Map.new(rows("SELECT * FROM groups"), &{&1["group_id"], &1})

    credit_orders =
      for {id, allocations} <- Enum.group_by(credit, & &1["group_id"]), into: %{} do
        ops = Enum.filter(operations, &(&1["result"]["group_id"] == id))
        group_cash = Enum.filter(cash, &(&1["group_id"] == id))
        model = replay(groups[id], group_cash, allocations, ops)

        blocks =
          model.allocations |> Enum.filter(&(&1.kind == :credit)) |> Enum.group_by(& &1.room)

        {orders, _} =
          Enum.map_reduce(allocations, blocks, fn row, blocks ->
            room = row["room_id"]
            room_blocks = Map.get(blocks, room, [])

            order =
              case room_blocks do
                [first | _] -> first.order
                [] -> 0
              end

            {{row["id"], order}, Map.put(blocks, room, consume(room_blocks, row["amount_cents"]))}
          end)

        {id, Map.new(orders)}
      end

    entries =
      Enum.map(cash, &{"cash_allocations", &1, &1["funding_order"], 0}) ++
        Enum.map(credit, &{"credit_allocations", &1, credit_orders[&1["group_id"]][&1["id"]], 1})

    entries
    |> Enum.sort_by(fn {_, row, order, kind} -> {order, kind, row["id"]} end)
    |> Enum.each(fn {table, row, _, _} ->
      %{rows: [[id]]} =
        repo().query!("INSERT INTO allocation_sequence DEFAULT VALUES RETURNING id")

      repo().query!("UPDATE #{table} SET allocation_order = ? WHERE id = ?", [id, row["id"]])
    end)
  end

  defp replay(group, cash, credit, ops) do
    nights =
      Date.diff(
        Date.from_iso8601!(group["departure_on"]),
        Date.from_iso8601!(group["arrival_on"])
      )

    rooms =
      Enum.map(Jason.decode!(group["rooms"]), fn room ->
        room = if is_binary(room), do: Jason.decode!(room), else: room
        lodging = nights * room["nightly_rate_cents"]

        {room["room_id"],
         if(group["rate_plan"] == "flexible", do: div(lodging * 20 + 50, 100), else: lodging)}
      end)

    legacy_cash =
      cash
      |> Enum.filter(&is_nil(&1["payment_operation_id"]))
      |> Enum.map(& &1["amount_cents"])
      |> Enum.sum()

    first_funding = Enum.find(ops, &(&1["type"] in ~w(record_cash_payment apply_hotel_credit)))

    recorded_credit =
      ops
      |> Enum.filter(&(&1["type"] == "apply_hotel_credit"))
      |> Enum.map(& &1["result"]["amount_cents"])
      |> Enum.sum()

    legacy_credit =
      if first_funding && is_integer(first_funding["result"]["outstanding_deposit_cents"]) do
        Enum.sum(Enum.map(rooms, &elem(&1, 1))) -
          first_funding["result"]["outstanding_deposit_cents"] -
          first_funding["result"]["amount_cents"] - legacy_cash
      else
        Enum.sum(Enum.map(credit, & &1["amount_cents"])) - recorded_credit
      end

    legacy_credit =
      if Enum.any?(ops, &(&1["type"] == "open_group")), do: 0, else: legacy_credit

    initial =
      %{rooms: rooms, allocations: []}
      |> fill(max(legacy_cash, 0), :cash, nil, 0)
      |> fill(max(legacy_credit, 0), :credit, nil, 0)

    Enum.reduce(ops, initial, fn op, state ->
      result = op["result"]

      case op["type"] do
        "record_cash_payment" ->
          fill(state, result["amount_cents"], :cash, op["operation_id"], op["id"])

        "apply_hotel_credit" ->
          fill(state, result["amount_cents"], :credit, nil, op["id"])

        type when type in ["cancel_rooms", "cancel_group"] ->
          selected =
            if type == "cancel_group",
              do: Enum.map(state.rooms, &elem(&1, 0)),
              else: result["cancelled_room_ids"]

          %{
            state
            | rooms: Enum.reject(state.rooms, &(elem(&1, 0) in selected)),
              allocations: Enum.reject(state.allocations, &(&1.room in selected))
          }

        type when type in ["reduce_cash_payment", "charge_back_payment"] ->
          payment = op["submission"]["payment_operation_id"]

          amount =
            if type == "charge_back_payment",
              do: Enum.sum(Enum.map(state.allocations, & &1.amount)),
              else: result["amount_cents"]

          {allocations, _} =
            Enum.map_reduce(Enum.reverse(state.allocations), amount, fn row, left ->
              used =
                if row.kind == :cash and row.payment == payment,
                  do: min(left, row.amount),
                  else: 0

              {%{row | amount: row.amount - used}, left - used}
            end)

          %{state | allocations: allocations |> Enum.reverse() |> Enum.reject(&(&1.amount == 0))}

        _ ->
          state
      end
    end)
  end

  defp fill(state, amount, kind, payment, order) do
    {rows, _} =
      Enum.map_reduce(state.rooms, amount, fn {room, due}, left ->
        paid =
          state.allocations
          |> Enum.filter(&(&1.room == room))
          |> Enum.map(& &1.amount)
          |> Enum.sum()

        used = min(left, max(due - paid, 0))
        {%{room: room, amount: used, kind: kind, payment: payment, order: order}, left - used}
      end)

    %{state | allocations: state.allocations ++ Enum.reject(rows, &(&1.amount == 0))}
  end

  defp consume(blocks, 0), do: blocks
  defp consume([], _), do: []

  defp consume([row | rest], needed) when row.amount > needed,
    do: [%{row | amount: row.amount - needed} | rest]

  defp consume([row | rest], needed), do: consume(rest, needed - row.amount)
end
