defmodule GroupStay.RoomAccountingBackfill do
  @moduledoc false

  @doc "Backfills room/source provenance without changing aggregate balances."
  def run(repo) do
    records = durable_records(repo)

    groups(repo)
    |> Enum.each(fn group ->
      sources = sources_for_group(records, group.group_id)
      ensure_payment_dispositions(repo, group, sources, records)
      backfill_credit_contributions(repo, group, sources, records)

      if group.status == "active" do
        backfill_active_group(repo, group, sources)
      end
    end)

    :ok
  end

  defp groups(repo) do
    repo.query!("""
    SELECT group_id, guest_id, status, cash_paid_cents, credit_paid_cents, deposit_paid_cents
    FROM groups
    """).rows
    |> Enum.map(fn [group_id, guest_id, status, cash_paid, credit_paid, deposit_paid] ->
      %{
        group_id: group_id,
        guest_id: guest_id,
        status: status,
        cash_paid: cash_paid || 0,
        credit_paid: credit_paid || 0,
        deposit_paid: deposit_paid || 0
      }
    end)
  end

  defp durable_records(repo) do
    repo.query!("SELECT id, operation_id, type, result FROM operation_records ORDER BY id").rows
    |> Enum.map(fn [id, operation_id, type, result] ->
      %{id: id, operation_id: operation_id, type: type, result: Jason.decode!(result)}
    end)
  end

  defp sources_for_group(records, group_id) do
    records
    |> Enum.filter(fn record ->
      result = record.result

      result["status"] == "applied" and result["group_id"] == group_id and
        record.type in ["record_cash_payment", "apply_hotel_credit"]
    end)
    |> Enum.map(fn record ->
      %{
        type: if(record.type == "record_cash_payment", do: :cash, else: :credit),
        operation_id: record.operation_id,
        amount: record.result["amount_cents"]
      }
    end)
  end

  defp backfill_active_group(repo, group, sources) do
    rooms = rooms(repo, group.group_id)
    cash_total = group.cash_paid
    durable_cash = sources |> Enum.filter(&(&1.type == :cash)) |> sum_amount()
    durable_credit = sources |> Enum.filter(&(&1.type == :credit)) |> sum_amount()
    cash_missing = max(cash_total - cash_allocated(repo, group.group_id), 0)
    legacy_cash = min(cash_missing, max(cash_total - durable_cash, 0))

    tag_untagged_credit(repo, group, durable_credit)
    rooms = allocate_legacy_cash(repo, group.group_id, rooms, legacy_cash)
    rooms = allocate_legacy_credit(repo, group.group_id, rooms)

    sources
    |> Enum.reduce({rooms, cash_missing - legacy_cash}, fn source, {rooms, remaining_cash} ->
      case source.type do
        :cash ->
          amount = min(source.amount, remaining_cash)
          rooms = allocate_cash(repo, group.group_id, rooms, source.operation_id, amount)
          {rooms, remaining_cash - amount}

        :credit ->
          {allocate_credit_rows(repo, group.group_id, rooms, source.operation_id), remaining_cash}
      end
    end)

    :ok
  end

  defp rooms(repo, group_id) do
    repo.query!(
      """
      SELECT id, room_id, position, deposit_due_cents, cash_paid_cents, credit_paid_cents
      FROM group_rooms WHERE group_id = ? AND status = 'active' ORDER BY position
      """,
      [group_id]
    ).rows
    |> Enum.map(fn [id, room_id, position, due, cash, credit] ->
      %{
        id: id,
        room_id: room_id,
        position: position,
        due: due || 0,
        cash: cash || 0,
        credit: credit || 0
      }
    end)
  end

  defp sum_amount(sources), do: Enum.reduce(sources, 0, &(&1.amount + &2))

  defp cash_allocated(repo, group_id) do
    case repo.query!(
           "SELECT COALESCE(SUM(amount_cents), 0) FROM cash_allocations WHERE group_id = ?",
           [group_id]
         ).rows do
      [[amount]] -> amount
    end
  end

  defp allocate_legacy_cash(repo, group_id, rooms, amount),
    do: allocate_cash(repo, group_id, rooms, nil, amount)

  defp allocate_cash(_repo, _group_id, rooms, _source, amount) when amount <= 0, do: rooms

  defp allocate_cash(repo, group_id, rooms, source, amount) do
    {rooms, _remaining} =
      Enum.map_reduce(rooms, amount, fn room, remaining ->
        capacity = max(room.due - room.cash - room.credit, 0)
        take = min(capacity, remaining)

        if take > 0 do
          repo.query!(
            "INSERT INTO cash_allocations (group_id, room_id, payment_operation_id, amount_cents) VALUES (?, ?, ?, ?)",
            [group_id, room.room_id, source, take]
          )

          repo.query!(
            "UPDATE group_rooms SET cash_paid_cents = cash_paid_cents + ? WHERE id = ?",
            [take, room.id]
          )
        end

        {%{room | cash: room.cash + take}, remaining - take}
      end)

    rooms
  end

  defp allocate_legacy_credit(repo, group_id, rooms),
    do: allocate_credit_rows(repo, group_id, rooms, nil)

  defp allocate_credit_rows(repo, group_id, rooms, source) do
    allocations =
      if is_nil(source) do
        repo.query!(
          "SELECT id, credit_lot_id, amount_cents, source_operation_id FROM credit_allocations WHERE group_id = ? AND room_id IS NULL AND source_operation_id IS NULL ORDER BY id",
          [group_id]
        ).rows
      else
        repo.query!(
          "SELECT id, credit_lot_id, amount_cents, source_operation_id FROM credit_allocations WHERE group_id = ? AND room_id IS NULL AND source_operation_id = ? ORDER BY id",
          [group_id, source]
        ).rows
      end

    rooms =
      Enum.reduce(allocations, rooms, fn [id, lot_id, amount, source_operation_id], rooms ->
        {room, rooms} =
          rooms
          |> Enum.split_while(&(max(&1.due - &1.cash - &1.credit, 0) == 0))
          |> case do
            {before, [room | after_rooms]} -> {room, before ++ [room | after_rooms]}
            {_before, []} -> {nil, rooms}
          end

        if room do
          capacity = max(room.due - room.cash - room.credit, 0)
          take = min(capacity, amount)

          repo.query!(
            "UPDATE credit_allocations SET room_id = ?, amount_cents = ? WHERE id = ?",
            [room.room_id, take, id]
          )

          repo.query!(
            "UPDATE group_rooms SET credit_paid_cents = credit_paid_cents + ? WHERE id = ?",
            [take, room.id]
          )

          rooms =
            update_room(rooms, room.id, fn current ->
              %{current | credit: current.credit + take}
            end)

          if take < amount do
            repo.query!(
              "INSERT INTO credit_allocations (group_id, credit_lot_id, amount_cents, source_operation_id) VALUES (?, ?, ?, ?)",
              [group_id, lot_id, amount - take, source_operation_id]
            )
          end

          rooms
        else
          rooms
        end
      end)

    remaining =
      if is_nil(source) do
        repo.query!(
          "SELECT COUNT(*) FROM credit_allocations WHERE group_id = ? AND room_id IS NULL AND source_operation_id IS NULL",
          [group_id]
        ).rows
      else
        repo.query!(
          "SELECT COUNT(*) FROM credit_allocations WHERE group_id = ? AND room_id IS NULL AND source_operation_id = ?",
          [group_id, source]
        ).rows
      end

    [[remaining_count]] = remaining

    if remaining_count > 0 and Enum.any?(rooms, &(max(&1.due - &1.cash - &1.credit, 0) > 0)) do
      allocate_credit_rows(repo, group_id, rooms, source)
    else
      rooms
    end
  end

  defp update_room(rooms, id, fun),
    do: Enum.map(rooms, fn room -> if room.id == id, do: fun.(room), else: room end)

  defp tag_untagged_credit(repo, group, durable_credit) do
    rows =
      repo.query!(
        "SELECT id, credit_lot_id, amount_cents FROM credit_allocations WHERE group_id = ? AND room_id IS NULL AND source_operation_id IS NULL ORDER BY id",
        [group.group_id]
      ).rows

    allocated_credit =
      Enum.reduce(rows, 0, fn [_id, _lot_id, amount], total -> total + amount end)

    legacy = max(allocated_credit - durable_credit, 0)

    sources =
      [
        {nil, legacy}
        | Enum.map(durable_sources(repo, group.group_id, :credit), &{&1.operation_id, &1.amount})
      ]

    Enum.reduce(rows, sources, fn [id, lot_id, amount], sources ->
      {segments, sources} = split(amount, sources)
      [{first_source, first_amount} | rest] = segments

      repo.query!(
        "UPDATE credit_allocations SET amount_cents = ?, source_operation_id = ? WHERE id = ?",
        [first_amount, first_source, id]
      )

      Enum.each(rest, fn {source, segment_amount} ->
        repo.query!(
          "INSERT INTO credit_allocations (group_id, credit_lot_id, amount_cents, source_operation_id) VALUES (?, ?, ?, ?)",
          [group.group_id, lot_id, segment_amount, source]
        )
      end)

      sources
    end)

    :ok
  end

  defp durable_sources(repo, group_id, type) do
    records = durable_records(repo)
    wanted = if type == :cash, do: "record_cash_payment", else: "apply_hotel_credit"

    Enum.flat_map(records, fn record ->
      if record.type == wanted and record.result["status"] == "applied" and
           record.result["group_id"] == group_id do
        [%{operation_id: record.operation_id, amount: record.result["amount_cents"]}]
      else
        []
      end
    end)
  end

  defp split(0, sources, segments), do: {Enum.reverse(segments), sources}
  defp split(amount, [{_source, 0} | rest], segments), do: split(amount, rest, segments)

  defp split(amount, [{source, available} | rest], segments) do
    take = min(amount, available)
    split(amount - take, [{source, available - take} | rest], [{source, take} | segments])
  end

  defp split(amount, [], segments), do: {Enum.reverse([{nil, amount} | segments]), []}
  defp split(amount, sources), do: split(amount, sources, [])

  defp ensure_payment_dispositions(repo, group, sources, records) do
    Enum.each(Enum.filter(sources, &(&1.type == :cash)), fn source ->
      exists =
        repo.query!("SELECT 1 FROM payment_dispositions WHERE payment_operation_id = ?", [
          source.operation_id
        ]).rows != []

      unless exists do
        {held, refunded, retained, converted} = historical_settlement(group, source, records)

        repo.query!(
          "INSERT INTO payment_dispositions (payment_operation_id, original_group_id, recorded_cents, held_cents, refunded_cents, retained_cents, converted_to_credit_cents) VALUES (?, ?, ?, ?, ?, ?, ?)",
          [
            source.operation_id,
            group.group_id,
            source.amount,
            held,
            refunded,
            retained,
            converted
          ]
        )
      end
    end)
  end

  defp historical_settlement(%{status: "active"}, source, _records), do: {source.amount, 0, 0, 0}

  defp historical_settlement(group, source, records) do
    cancellation =
      Enum.find(records, fn record ->
        record.type == "cancel_group" and record.result["status"] == "applied" and
          record.result["group_id"] == group.group_id
      end)

    result = cancellation && cancellation.result

    cond do
      result && result["refunded_cents"] > 0 -> {0, source.amount, 0, 0}
      result && result["retained_cents"] > 0 -> {0, 0, source.amount, 0}
      result && result["credit_issued_cents"] > 0 -> {0, 0, 0, source.amount}
      true -> {0, 0, 0, 0}
    end
  end

  defp backfill_credit_contributions(repo, group, sources, records) do
    cancellation =
      Enum.find(records, fn record ->
        result = record.result

        record.type == "cancel_group" and result["status"] == "applied" and
          result["group_id"] == group.group_id and (result["credit_issued_cents"] || 0) > 0
      end)

    if cancellation do
      lot =
        repo.query!(
          "SELECT id FROM credit_lots WHERE guest_id = ? AND source_operation_id = ? LIMIT 1",
          [group.guest_id, cancellation.operation_id]
        ).rows

      case lot do
        [[lot_id]] ->
          existing =
            repo.query!(
              "SELECT COUNT(*) FROM credit_lot_contributions WHERE credit_lot_id = ?",
              [lot_id]
            ).rows

          [[count]] = existing

          if count == 0 do
            durable_cash = sources |> Enum.filter(&(&1.type == :cash))
            durable_cash_total = sum_amount(durable_cash)
            legacy_cash = max(group.cash_paid - durable_cash_total, 0)
            contributions = [%{operation_id: nil, amount: legacy_cash} | durable_cash]

            insert_credit_contributions(repo, lot_id, contributions)
          end

        _ ->
          :ok
      end
    end

    :ok
  end

  defp insert_credit_contributions(repo, lot_id, sources) do
    {_, _} =
      Enum.reduce(Enum.reject(sources, &(&1.amount <= 0)), {0, 0}, fn source,
                                                                      {running_cash,
                                                                       running_credit} ->
        next_cash = running_cash + source.amount
        next_credit = credit_value(next_cash)

        repo.query!(
          "INSERT INTO credit_lot_contributions (credit_lot_id, payment_operation_id, entitlement_cents) VALUES (?, ?, ?)",
          [lot_id, source.operation_id, next_credit - running_credit]
        )

        {next_cash, next_credit}
      end)
  end

  defp credit_value(cash), do: cash + div(cash * 10 + 50, 100)
end
