defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    create table(:allocation_sequence) do
    end

    for table <- [:cash_allocations, :credit_allocations] do
      alter table(table) do
        add :allocation_order, :integer
      end
    end

    create table(:transferred_payments, primary_key: false) do
      add :payment_operation_id, :string, primary_key: true
    end

    flush()
    backfill_order()

    # SQLite serializes operation writers. A shared sequence gives both funding
    # kinds one durable creation order, including slices created by transfers.
    for table <- [:cash_allocations, :credit_allocations] do
      execute """
      CREATE TRIGGER #{table}_assign_order AFTER INSERT ON #{table}
      WHEN NEW.allocation_order IS NULL
      BEGIN
        INSERT INTO allocation_sequence (id) VALUES (NULL);
        UPDATE #{table} SET allocation_order = last_insert_rowid() WHERE id = NEW.id;
      END
      """
    end
  end

  def down do
    for table <- [:cash_allocations, :credit_allocations] do
      execute "DROP TRIGGER #{table}_assign_order"
      alter table(table), do: remove(:allocation_order)
    end

    drop table(:transferred_payments)
    drop table(:allocation_sequence)
  end

  # Reconstruct credit application boundaries from the durable room-filling
  # history. Credit rows retain lots, but older releases did not retain the
  # application identity. Room cancellation removes whole allocations; cash
  # corrections reopen space and must be replayed before subsequent funding.
  # This is a frozen, in-memory accounting replay: no balances or audit entries
  # are changed by the upgrade.
  defp backfill_order do
    records =
      rows("SELECT id, operation_id, type, result FROM operations ORDER BY id")
      |> Enum.map(fn [id, operation_id, type, result] ->
        %{id: id, operation_id: operation_id, type: type, result: Jason.decode!(result)}
      end)
      |> Enum.filter(&(&1.result["status"] == "applied"))

    cash =
      rows(
        "SELECT id, group_id, room_id, payment_operation_id, amount_cents FROM cash_allocations ORDER BY id"
      )

    credit =
      rows("SELECT id, group_id, room_id, amount_cents FROM credit_allocations ORDER BY id")

    payment_order = Map.new(records, &{&1.operation_id, &1.id})

    credit_orders =
      for [group_id, encoded] <- rows("SELECT group_id, rooms FROM groups"), reduce: %{} do
        orders ->
          rooms =
            Enum.map(Jason.decode!(encoded), fn room ->
              if is_binary(room), do: Jason.decode!(room), else: room
            end)

          history = Enum.filter(records, &(&1.result["group_id"] == group_id))
          group_cash = Enum.filter(cash, &(Enum.at(&1, 1) == group_id))
          group_credit = Enum.filter(credit, &(Enum.at(&1, 1) == group_id))

          virtual =
            if group_credit == [], do: %{}, else: replay(rooms, history, group_cash, group_credit)

          {orders, _remaining} =
            Enum.reduce(group_credit, {orders, virtual}, fn [id, _, room, amount],
                                                            {orders, virtual} ->
              slices = Map.get(virtual, room, [])
              {order, slices} = take_credit(slices, amount)
              {Map.put(orders, id, order), Map.put(virtual, room, slices)}
            end)

          orders
      end

    ordered =
      Enum.map(cash, fn [id, _, _, payment, _] ->
        {"cash_allocations", id, {Map.get(payment_order, payment, 0), 0, id}}
      end) ++
        Enum.map(credit, fn [id, _, _, _] ->
          {"credit_allocations", id, {Map.fetch!(credit_orders, id), 1, id}}
        end)

    for {{table, id, _}, order} <- ordered |> Enum.sort_by(&elem(&1, 2)) |> Enum.with_index(1) do
      repo().query!("INSERT INTO allocation_sequence (id) VALUES (?)", [order])
      repo().query!("UPDATE #{table} SET allocation_order = ? WHERE id = ?", [order, id])
    end
  end

  defp replay(rooms, history, cash, credit) do
    {before, funding} =
      Enum.split_while(history, &(&1.type not in ["record_cash_payment", "apply_hotel_credit"]))

    cancelled = Enum.flat_map(before, &cancelled_ids(&1, rooms))

    rooms =
      Enum.map(
        rooms,
        &%{
          id: &1["room_id"],
          due: &1["deposit_due_cents"],
          active: &1["room_id"] not in cancelled
        }
      )

    legacy_cash =
      for [_, _, room, nil, amount] <- cash,
          do: %{room: room, amount: amount, kind: :cash, payment: nil, order: 0}

    legacy_cash =
      Enum.filter(legacy_cash, fn slice ->
        Enum.any?(rooms, &(&1.id == slice.room and &1.active))
      end)

    legacy_credit =
      case funding do
        [%{result: %{"outstanding_deposit_cents" => outstanding, "amount_cents" => amount}} | _] ->
          Enum.sum(for room <- rooms, room.active, do: room.due) - outstanding - amount -
            total(legacy_cash)

        _ ->
          # Unattributed funding can predate durable operation results.
          Enum.sum(for [_, _, _, amount] <- credit, do: amount) -
            Enum.sum(
              for record <- funding,
                  record.type == "apply_hotel_credit",
                  do: record.result["amount_cents"]
            )
      end

    slices = fill(rooms, legacy_cash, max(legacy_credit, 0), :credit, nil, 0)

    {_rooms, slices} =
      Enum.reduce(funding, {rooms, slices}, fn record, {rooms, slices} ->
        case record.type do
          type when type in ["record_cash_payment", "apply_hotel_credit"] ->
            kind = if type == "record_cash_payment", do: :cash, else: :credit

            {rooms,
             fill(
               rooms,
               slices,
               record.result["amount_cents"],
               kind,
               record.operation_id,
               record.id
             )}

          type when type in ["cancel_group", "cancel_rooms"] ->
            ids = cancelled_ids(record, Enum.map(rooms, &%{"room_id" => &1.id}))

            {Enum.map(rooms, fn room ->
               if room.id in ids, do: %{room | active: false}, else: room
             end), Enum.reject(slices, &(&1.room in ids))}

          type when type in ["reduce_cash_payment", "charge_back_payment"] ->
            payment = record.result["payment_operation_id"]

            amount =
              if type == "reduce_cash_payment",
                do: record.result["amount_cents"],
                else: total(Enum.filter(slices, &(&1.payment == payment and &1.kind == :cash)))

            {rooms, remove_payment(slices, payment, amount)}

          _ ->
            {rooms, slices}
        end
      end)

    slices |> Enum.filter(&(&1.kind == :credit)) |> Enum.group_by(& &1.room)
  end

  defp fill(rooms, slices, amount, kind, payment, order) do
    {slices, 0} =
      Enum.reduce(rooms, {slices, amount}, fn room, {slices, remaining} ->
        paid = total(Enum.filter(slices, &(&1.room == room.id)))
        used = if room.active, do: min(remaining, room.due - paid), else: 0

        added =
          if used > 0,
            do: [%{room: room.id, amount: used, kind: kind, payment: payment, order: order}],
            else: []

        {slices ++ added, remaining - used}
      end)

    slices
  end

  defp remove_payment(slices, payment, amount) do
    {slices, _} =
      slices
      |> Enum.reverse()
      |> Enum.map_reduce(amount, fn slice, remaining ->
        used =
          if slice.kind == :cash and slice.payment == payment,
            do: min(remaining, slice.amount),
            else: 0

        {%{slice | amount: slice.amount - used}, remaining - used}
      end)

    slices |> Enum.reverse() |> Enum.reject(&(&1.amount == 0))
  end

  defp take_credit([slice | rest], amount) when amount <= slice.amount do
    remaining =
      if amount == slice.amount, do: rest, else: [%{slice | amount: slice.amount - amount} | rest]

    {slice.order, remaining}
  end

  defp cancelled_ids(%{type: "cancel_group"}, rooms), do: Enum.map(rooms, & &1["room_id"])
  defp cancelled_ids(%{type: "cancel_rooms", result: result}, _), do: result["cancelled_room_ids"]
  defp cancelled_ids(_, _), do: []
  defp total(slices), do: Enum.sum(Enum.map(slices, & &1.amount))
  defp rows(sql), do: repo().query!(sql).rows
end
