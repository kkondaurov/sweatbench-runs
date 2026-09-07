defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    create table(:allocation_sequence, primary_key: false) do
      add :id, :integer, primary_key: true
      add :value, :integer, null: false
    end

    alter table(:cash_allocations), do: add(:allocation_order, :integer)
    alter table(:credit_allocations), do: add(:allocation_order, :integer)

    create table(:transferred_payments, primary_key: false) do
      add :payment_operation_id, :text, primary_key: true
    end

    flush()
    repo().query!("INSERT INTO allocation_sequence (id, value) VALUES (1, 0)")
    backfill_order()
  end

  # Separate cash/credit row IDs cannot establish their relative creation order.
  # Replay only the old room-allocation rules from the immutable journal, then
  # label surviving rows. No balances, lots, revisions or results are rewritten.
  # This also handles refills of earlier rooms after a provider correction.
  defp backfill_order do
    entries =
      rows("SELECT * FROM operations ORDER BY id")
      |> Enum.map(fn entry ->
        entry |> Map.update!("result", &decode/1) |> Map.update!("submission", &decode/1)
      end)
      |> Enum.filter(&(&1["result"]["status"] == "applied"))

    orders = Map.new(entries, &{&1["operation_id"], &1["id"]})

    for group <- rows("SELECT * FROM groups ORDER BY group_id") do
      rooms = decode(group["rooms"])

      cash =
        rows("SELECT * FROM cash_allocations WHERE group_id = ? ORDER BY id", [group["group_id"]])

      credit =
        rows("SELECT * FROM credit_allocations WHERE group_id = ? ORDER BY id", [
          group["group_id"]
        ])

      history = Enum.filter(entries, &(&1["result"]["group_id"] == group["group_id"]))
      funding = Enum.find(history, &(&1["type"] in ~w(record_cash_payment apply_hotel_credit)))
      prior = if funding, do: Enum.take_while(history, &(&1["id"] < funding["id"])), else: history
      cancelled = Enum.flat_map(prior, &cancelled_rooms(&1, rooms))
      active = Enum.reject(rooms, &(&1["room_id"] in cancelled))

      legacy_cash =
        Enum.filter(
          cash,
          &(is_nil(&1["payment_operation_id"]) and &1["room_id"] not in cancelled)
        )

      initial_cash =
        Enum.map(
          legacy_cash,
          &%{kind: :cash, payment: nil, room: &1["room_id"], amount: &1["amount_cents"], order: 0}
        )

      legacy_credit =
        if funding && is_integer(funding["result"]["outstanding_deposit_cents"]) do
          Enum.sum(Enum.map(active, & &1["deposit_due_cents"])) -
            funding["result"]["outstanding_deposit_cents"] - funding["result"]["amount_cents"] -
            Enum.sum(Enum.map(initial_cash, & &1.amount))
        else
          # Older migration fixtures and pre-journal groups may not have a full
          # funding result. Their surviving senior balance is still identifiable.
          recorded =
            history
            |> Enum.filter(&(&1["type"] == "apply_hotel_credit"))
            |> Enum.map(& &1["result"]["amount_cents"])
            |> Enum.sum()

          max(Enum.sum(Enum.map(credit, & &1["amount_cents"])) - recorded, 0)
        end

      state = %{rooms: active, portions: initial_cash}
      state = fund(state, :credit, nil, max(legacy_credit, 0), 0)
      history = if funding, do: Enum.drop_while(history, &(&1["id"] < funding["id"])), else: []
      state = Enum.reduce(history, state, &replay/2)

      labels = cash_labels(cash, rooms, orders) ++ credit_labels(credit, rooms, state.portions)

      for {table, id, _} <- Enum.sort_by(labels, &elem(&1, 2)) do
        repo().query!("UPDATE allocation_sequence SET value = value + 1 WHERE id = 1")

        repo().query!(
          "UPDATE #{table} SET allocation_order = (SELECT value FROM allocation_sequence WHERE id = 1) WHERE id = ?",
          [id]
        )
      end
    end
  end

  defp cash_labels(cash, rooms, orders) do
    Enum.map(cash, fn row ->
      position = Enum.find_index(rooms, &(&1["room_id"] == row["room_id"])) || 0

      {"cash_allocations", row["id"],
       {Map.get(orders, row["payment_operation_id"], 0), position, 0, row["id"]}}
    end)
  end

  defp credit_labels(credit, rooms, portions) do
    {credit_labels, _} =
      Enum.map_reduce(credit, portions, fn row, portions ->
        portion =
          Enum.find(
            portions,
            &(&1.kind == :credit and &1.room == row["room_id"] and &1.amount > 0)
          )

        order = if portion, do: portion.order, else: 0
        position = Enum.find_index(rooms, &(&1["room_id"] == row["room_id"])) || 0

        portions =
          if portion,
            do: consume_credit(portions, row["room_id"], row["amount_cents"]),
            else: portions

        {{"credit_allocations", row["id"], {order, position, 1, row["id"]}}, portions}
      end)

    credit_labels
  end

  defp replay(entry, state) do
    result = entry["result"]

    case entry["type"] do
      "record_cash_payment" ->
        fund(state, :cash, entry["operation_id"], result["amount_cents"], entry["id"])

      "apply_hotel_credit" ->
        fund(state, :credit, nil, result["amount_cents"], entry["id"])

      type when type in ~w(cancel_group cancel_rooms) ->
        ids = cancelled_rooms(entry, state.rooms)

        %{
          state
          | rooms: Enum.reject(state.rooms, &(&1["room_id"] in ids)),
            portions: Enum.reject(state.portions, &(&1.room in ids))
        }

      "reduce_cash_payment" ->
        payment = entry["submission"]["payment_operation_id"]

        positions =
          state.rooms |> Enum.with_index() |> Map.new(fn {room, i} -> {room["room_id"], i} end)

        {portions, _} =
          state.portions
          |> Enum.sort_by(&{Map.get(positions, &1.room, -1), &1.order}, :desc)
          |> Enum.map_reduce(result["amount_cents"], fn portion, needed ->
            used =
              if portion.kind == :cash and portion.payment == payment,
                do: min(needed, portion.amount),
                else: 0

            {%{portion | amount: portion.amount - used}, needed - used}
          end)

        %{state | portions: Enum.sort_by(portions, & &1.order)}

      "charge_back_payment" ->
        payment = entry["submission"]["payment_operation_id"]

        %{
          state
          | portions: Enum.reject(state.portions, &(&1.kind == :cash and &1.payment == payment))
        }

      _ ->
        state
    end
  end

  defp fund(state, kind, payment, amount, order) do
    {new, _} =
      Enum.map_reduce(state.rooms, amount, fn room, needed ->
        held =
          state.portions
          |> Enum.filter(&(&1.room == room["room_id"]))
          |> Enum.map(& &1.amount)
          |> Enum.sum()

        used = min(needed, max(room["deposit_due_cents"] - held, 0))

        {%{kind: kind, payment: payment, room: room["room_id"], amount: used, order: order},
         needed - used}
      end)

    %{state | portions: state.portions ++ Enum.filter(new, &(&1.amount > 0))}
  end

  defp consume_credit(portions, room, amount) do
    {portions, _} =
      Enum.map_reduce(portions, amount, fn portion, needed ->
        used =
          if portion.kind == :credit and portion.room == room,
            do: min(needed, portion.amount),
            else: 0

        {%{portion | amount: portion.amount - used}, needed - used}
      end)

    portions
  end

  defp cancelled_rooms(%{"type" => "cancel_group"}, rooms), do: Enum.map(rooms, & &1["room_id"])

  defp cancelled_rooms(%{"type" => "cancel_rooms", "result" => result}, _),
    do: result["cancelled_room_ids"]

  defp cancelled_rooms(_, _), do: []
  defp decode(value) when is_binary(value), do: Jason.decode!(value)
  defp decode(value), do: value

  defp rows(sql, params \\ []) do
    %{columns: columns, rows: rows} = repo().query!(sql, params)
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end

  def down do
    drop table(:transferred_payments)
    alter table(:credit_allocations), do: remove(:allocation_order)
    alter table(:cash_allocations), do: remove(:allocation_order)
    drop table(:allocation_sequence)
  end
end
