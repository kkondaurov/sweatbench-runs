defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    for table <- [:cash_allocations, :credit_allocations] do
      alter table(table) do
        add :allocation_order, :integer, null: false, default: 0
      end
    end

    create table(:allocation_sequence, primary_key: false) do
      add :position, :integer, null: false
    end

    create table(:transferred_payments, primary_key: false) do
      add :payment_operation_id, :string, primary_key: true
    end

    execute(&backfill/0)
  end

  def down do
    drop table(:transferred_payments)
    drop table(:allocation_sequence)

    for table <- [:cash_allocations, :credit_allocations] do
      alter table(table), do: remove(:allocation_order)
    end
  end

  # The old tables had independent ID sequences. Cash retains its receipt ID,
  # but credit retains only its lot. Replay room occupancy (not money or lots)
  # to recover the receipt that created each surviving credit slice. This also
  # handles holes left by room cancellations, reductions, and chargebacks.
  # Keep the upgrade independent of application schemas and execution code.
  defp backfill do
    records =
      rows("SELECT id, operation_id, type, result FROM operations ORDER BY id")
      |> Enum.map(&Map.update!(&1, "result", fn result -> Jason.decode!(result) end))
      |> Enum.filter(&(&1["result"]["status"] == "applied"))

    receipt_order = Map.new(records, &{&1["operation_id"], &1["id"]})
    cash = rows("SELECT * FROM cash_allocations ORDER BY id")
    credit = rows("SELECT * FROM credit_allocations ORDER BY id")

    credit_order =
      for group <- rows("SELECT * FROM groups"),
          allocation <- credit_order(group, records, cash, credit),
          into: %{},
          do: allocation

    ordered =
      Enum.map(cash, fn allocation ->
        {Map.get(receipt_order, allocation["payment_operation_id"], -1), allocation["id"],
         "cash_allocations"}
      end) ++
        Enum.map(credit, fn allocation ->
          {Map.fetch!(credit_order, allocation["id"]), allocation["id"], "credit_allocations"}
        end)

    ordered
    |> Enum.sort()
    |> Enum.with_index(1)
    |> Enum.each(fn {{_receipt, id, table}, position} ->
      query("UPDATE #{table} SET allocation_order = ? WHERE id = ?", [position, id])
    end)

    query("INSERT INTO allocation_sequence (position) VALUES (?)", [length(ordered)])
  end

  # Replay slices carry {kind, payment_id, receipt_order, cents}. Lot boundaries
  # come from the surviving rows; replay only recovers their creation order.
  # Orders -1 and 0 put senior cash before senior credit, ahead of all receipts.
  defp credit_order(group, records, cash, credit) do
    group_id = group["group_id"]
    credit = Enum.filter(credit, &(&1["group_id"] == group_id))

    if credit == [] do
      []
    else
      cash = Enum.filter(cash, &(&1["group_id"] == group_id))
      records = Enum.filter(records, &(&1["result"]["group_id"] == group_id))
      {before_funding, funding_onward} = Enum.split_while(records, &(not funding?(&1)))
      rooms = Enum.reduce(before_funding, original_rooms(group), &replay/2)

      # Unattributed cash is senior to unattributed credit. Settled cash slices
      # still identify their original room and are needed when replaying history.
      rooms =
        Enum.map(rooms, fn room ->
          amount =
            cash
            |> Enum.filter(&(&1["payment_operation_id"] == nil and &1["room_id"] == room.id))
            |> Enum.map(& &1["amount_cents"])
            |> Enum.sum()

          if room.active, do: %{room | slices: [{:cash, nil, -1, amount}]}, else: room
        end)

      senior_credit = senior_credit(rooms, funding_onward, credit)
      rooms = fill(rooms, :credit, nil, 0, senior_credit)
      rooms = Enum.reduce(funding_onward, rooms, &replay/2)

      Enum.flat_map(rooms, fn room ->
        slices = for {:credit, _, order, amount} <- room.slices, do: {order, amount}
        allocations = Enum.filter(credit, &(&1["room_id"] == room.id))

        {positions, []} =
          Enum.map_reduce(allocations, slices, fn allocation, [{order, amount} | rest] ->
            remaining = amount - allocation["amount_cents"]
            true = remaining >= 0
            rest = if remaining == 0, do: rest, else: [{order, remaining} | rest]
            {{allocation["id"], order}, rest}
          end)

        positions
      end)
    end
  end

  defp senior_credit(rooms, [first | _] = records, credit) do
    if Enum.any?(records, &(&1["type"] in ["cancel_group", "cancel_rooms"])) do
      # The first funding receipt captures occupancy before any later room
      # settlements removed credit. Earlier cancellations are already reflected
      # in the active rooms passed here.
      outstanding = first["result"]["outstanding_deposit_cents"]
      due = rooms |> Enum.filter(& &1.active) |> Enum.map(& &1.due) |> Enum.sum()
      cash = rooms |> Enum.flat_map(& &1.slices) |> Enum.map(&elem(&1, 3)) |> Enum.sum()
      due - outstanding - first["result"]["amount_cents"] - cash
    else
      recorded =
        for record <- records,
            record["type"] == "apply_hotel_credit",
            do: record["result"]["amount_cents"]

      Enum.sum(Enum.map(credit, & &1["amount_cents"])) - Enum.sum(recorded)
    end
  end

  defp senior_credit(_rooms, [], credit),
    do: Enum.sum(Enum.map(credit, & &1["amount_cents"]))

  defp original_rooms(group) do
    nights =
      Date.diff(
        Date.from_iso8601!(group["departure_on"]),
        Date.from_iso8601!(group["arrival_on"])
      )

    for room <- Jason.decode!(group["rooms"]) do
      lodging = nights * room["nightly_rate_cents"]
      due = if group["rate_plan"] == "flexible", do: div(lodging * 20 + 50, 100), else: lodging
      %{id: room["room_id"], due: due, active: true, slices: []}
    end
  end

  defp funding?(record), do: record["type"] in ["record_cash_payment", "apply_hotel_credit"]

  defp replay(%{"type" => type} = record, rooms)
       when type in ["record_cash_payment", "apply_hotel_credit"] do
    kind = if type == "record_cash_payment", do: :cash, else: :credit
    fill(rooms, kind, record["operation_id"], record["id"], record["result"]["amount_cents"])
  end

  defp replay(%{"type" => type} = record, rooms) when type in ["cancel_group", "cancel_rooms"] do
    Enum.map(rooms, fn room ->
      if type == "cancel_group" or room.id in record["result"]["cancelled_room_ids"],
        do: %{room | active: false, slices: []},
        else: room
    end)
  end

  defp replay(%{"type" => type} = record, rooms)
       when type in ["reduce_cash_payment", "charge_back_payment"] do
    payment_id = record["result"]["payment_operation_id"]
    amount = record["result"]["amount_cents"] || record["result"]["charged_back_cents"]

    {rooms, _remaining} =
      Enum.map_reduce(Enum.reverse(rooms), amount, fn room, remaining ->
        {slices, remaining} =
          Enum.map_reduce(Enum.reverse(room.slices), remaining, fn
            {:cash, ^payment_id, order, cents}, remaining ->
              removed = min(remaining, cents)
              {{:cash, payment_id, order, cents - removed}, remaining - removed}

            slice, remaining ->
              {slice, remaining}
          end)

        {%{room | slices: slices |> Enum.reverse() |> Enum.reject(&(elem(&1, 3) == 0))},
         remaining}
      end)

    Enum.reverse(rooms)
  end

  defp replay(_record, rooms), do: rooms

  defp fill(rooms, kind, source, order, amount) do
    {rooms, 0} =
      Enum.map_reduce(rooms, amount, fn room, remaining ->
        used = Enum.sum(Enum.map(room.slices, &elem(&1, 3)))
        added = if room.active, do: min(remaining, room.due - used), else: 0

        slices =
          if added > 0, do: room.slices ++ [{kind, source, order, added}], else: room.slices

        {%{room | slices: slices}, remaining - added}
      end)

    rooms
  end

  defp query(sql, params), do: repo().query!(sql, params)

  defp rows(sql) do
    result = query(sql, [])
    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end
end
