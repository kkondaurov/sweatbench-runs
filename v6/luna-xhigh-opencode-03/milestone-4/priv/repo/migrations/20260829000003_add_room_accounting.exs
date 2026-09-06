defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:group_rooms) do
      add :deposit_due_cents, :integer, null: false, default: 0
      add :status, :text, null: false, default: "active"
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:group_credit_allocations) do
      add :group_room_id, references(:group_rooms, on_delete: :delete_all)
      add :source_operation_id, :text
      add :status, :text, null: false, default: "held"
    end

    create index(:group_credit_allocations, [:group_room_id])

    create table(:cash_allocations) do
      add :group_record_id, references(:groups, on_delete: :delete_all), null: false
      add :group_room_id, references(:group_rooms, on_delete: :delete_all), null: false
      add :payment_operation_id, :text
      add :amount_cents, :integer, null: false
      add :disposition, :text, null: false, default: "held"
      add :credit_lot_id, references(:credit_lots, on_delete: :restrict)
    end

    create index(:cash_allocations, [:group_record_id, :group_room_id])
    create index(:cash_allocations, [:payment_operation_id])
    create index(:cash_allocations, [:credit_lot_id])

    create table(:credit_lot_entitlements) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :payment_operation_id, :text, null: false
      add :amount_cents, :integer, null: false
      add :revoked_cents, :integer, null: false, default: 0
    end

    create unique_index(:credit_lot_entitlements, [:credit_lot_id, :payment_operation_id])
    create index(:credit_lot_entitlements, [:payment_operation_id])

    flush()
    backfill_room_accounting()
  end

  def down do
    drop table(:credit_lot_entitlements)
    drop table(:cash_allocations)
    drop index(:group_credit_allocations, [:group_room_id])

    alter table(:group_credit_allocations) do
      remove :status
      remove :source_operation_id
      remove :group_room_id
    end

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:group_rooms) do
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :status
      remove :deposit_due_cents
    end

    alter table(:groups) do
      remove :cash_charged_back_cents
      remove :cash_reduced_cents
    end
  end

  defp backfill_room_accounting do
    groups =
      repo().query!(
        "SELECT id, group_id, guest_id, arrival_on, departure_on, rate_plan, status, " <>
          "cash_paid_cents, credit_paid_cents FROM groups ORDER BY id"
      ).rows

    operation_rows =
      repo().query!(
        "SELECT id, operation_id, operation_type, result_json " <>
          "FROM operation_records ORDER BY id"
      ).rows

    Enum.each(groups, fn [
                           group_record_id,
                           group_id,
                           guest_id,
                           arrival,
                           departure,
                           rate_plan,
                           group_status,
                           cash_paid,
                           credit_paid
                         ] ->
      rooms = backfill_rooms(group_record_id, arrival, departure, rate_plan, group_status)

      [refunded, retained, converted] =
        repo().query!(
          "SELECT refunded_cents, retained_cents, cash_converted_to_credit_cents " <>
            "FROM groups WHERE id = ?",
          [group_record_id]
        ).rows
        |> List.first()

      recorded = recorded_funding(operation_rows, group_id)
      legacy_cash = max(cash_paid - sum_amount(recorded, :cash), 0)
      legacy_credit = max(credit_paid - sum_amount(recorded, :credit), 0)

      old_credit_rows =
        repo().query!(
          "SELECT id, credit_lot_id, amount_cents FROM group_credit_allocations " <>
            "WHERE group_record_id = ? ORDER BY id",
          [group_record_id]
        ).rows

      credit_pieces =
        split_credit_sources(
          Enum.map(old_credit_rows, fn [_id, lot_id, amount] -> {lot_id, amount} end),
          [
            {nil, legacy_credit}
            | Enum.filter(recorded, &(&1.kind == :credit))
              |> Enum.map(&{&1.source, &1.amount})
          ]
        )

      repo().query!("DELETE FROM group_credit_allocations WHERE group_record_id = ?", [
        group_record_id
      ])

      events =
        [
          %{kind: :cash, source: nil, amount: legacy_cash},
          %{kind: :credit, source: nil, amount: legacy_credit, pieces: credit_pieces}
          | Enum.map(recorded, fn funding ->
              funding
              |> Map.take([:kind, :source, :amount])
              |> Map.put(:pieces, credit_pieces)
            end)
        ]

      {room_allocations, _remaining} = allocate_events(events, rooms)

      cash_disposition =
        historical_cash_disposition(group_status, cash_paid, refunded, retained, converted)

      credit_lot_id =
        historical_credit_lot_id(group_status, converted, guest_id, group_id, operation_rows)

      Enum.each(room_allocations, fn
        %{kind: :cash, room_id: room_id, source: source, amount: amount} ->
          repo().query!(
            "INSERT INTO cash_allocations " <>
              "(group_record_id, group_room_id, payment_operation_id, amount_cents, disposition, credit_lot_id) " <>
              "VALUES (?, ?, ?, ?, ?, ?)",
            [group_record_id, room_id, source, amount, cash_disposition, credit_lot_id]
          )

          repo().query!(
            "UPDATE group_rooms SET cash_paid_cents = cash_paid_cents + ? WHERE id = ?",
            [amount, room_id]
          )

        %{kind: :credit, room_id: room_id, source: source, lot_id: lot_id, amount: amount} ->
          repo().query!(
            "INSERT INTO group_credit_allocations " <>
              "(group_record_id, group_room_id, credit_lot_id, amount_cents, " <>
              "source_operation_id, status) VALUES (?, ?, ?, ?, ?, 'held')",
            [group_record_id, room_id, lot_id, amount, source]
          )

          repo().query!(
            "UPDATE group_rooms SET credit_paid_cents = credit_paid_cents + ? WHERE id = ?",
            [amount, room_id]
          )
      end)

      if cash_disposition == "converted" and credit_lot_id != nil do
        insert_historical_entitlements(room_allocations, credit_lot_id)
      end
    end)
  end

  defp historical_cash_disposition("active", _cash_paid, _refunded, _retained, _converted),
    do: "held"

  defp historical_cash_disposition("cancelled", cash_paid, refunded, retained, converted) do
    if cash_paid == 0 do
      "held"
    else
      cond do
        converted > 0 -> "converted"
        refunded > 0 -> "refunded"
        retained > 0 -> "retained"
        true -> "retained"
      end
    end
  end

  defp historical_cash_disposition(_status, _cash_paid, _refunded, _retained, _converted),
    do: "held"

  defp historical_credit_lot_id("active", _converted, _guest_id, _group_id, _operation_rows),
    do: nil

  defp historical_credit_lot_id("cancelled", converted, guest_id, group_id, operation_rows) do
    if converted == 0 do
      nil
    else
      cancellation =
        Enum.find_value(operation_rows, fn
          [_id, operation_id, "cancel_group", result_json] ->
            case Jason.decode(result_json) do
              {:ok, %{"status" => "applied", "group_id" => ^group_id}} -> operation_id
              _ -> nil
            end

          [_id, _operation_id, _type, _result_json] ->
            nil
        end)

      case cancellation do
        nil ->
          nil

        operation_id ->
          case repo().query!(
                 "SELECT id FROM credit_lots WHERE guest_id = ? AND source_operation_id = ? " <>
                   "ORDER BY id LIMIT 1",
                 [guest_id, operation_id]
               ).rows do
            [[lot_id]] -> lot_id
            _ -> nil
          end
      end
    end
  end

  defp insert_historical_entitlements(room_allocations, lot_id) do
    room_allocations
    |> Enum.filter(&(&1.kind == :cash))
    |> Enum.reduce({0, nil, 0}, fn allocation, {running, source, source_amount} ->
      if allocation.source == source do
        {running + allocation.amount, source, source_amount + allocation.amount}
      else
        insert_historical_entitlement(lot_id, source, running, source_amount)
        {running + allocation.amount, allocation.source, allocation.amount}
      end
    end)
    |> then(fn {running, source, source_amount} ->
      insert_historical_entitlement(lot_id, source, running, source_amount)
    end)
  end

  defp insert_historical_entitlement(_lot_id, nil, _running, _source_amount), do: :ok
  defp insert_historical_entitlement(_lot_id, _source, _running, 0), do: :ok

  defp insert_historical_entitlement(lot_id, source, running, source_amount) do
    previous = running - source_amount
    amount = credit_value(running) - credit_value(previous)

    if amount > 0 do
      repo().query!(
        "INSERT INTO credit_lot_entitlements " <>
          "(credit_lot_id, payment_operation_id, amount_cents, revoked_cents) VALUES (?, ?, ?, 0)",
        [lot_id, source, amount]
      )
    end
  end

  defp backfill_rooms(group_record_id, arrival, departure, rate_plan, group_status) do
    arrival = Date.from_iso8601!(arrival)
    departure = Date.from_iso8601!(departure)
    nights = Date.diff(departure, arrival)

    repo().query!(
      "SELECT id, nightly_rate_cents, position FROM group_rooms " <>
        "WHERE group_record_id = ? ORDER BY position, id",
      [group_record_id]
    ).rows
    |> Enum.map(fn [room_id, nightly_rate, position] ->
      due = room_deposit(rate_plan, nightly_rate, nights)

      repo().query!(
        "UPDATE group_rooms SET deposit_due_cents = ?, status = ?, " <>
          "cash_paid_cents = 0, credit_paid_cents = 0 WHERE id = ?",
        [due, group_status, room_id]
      )

      %{room_id: room_id, position: position, due: due, remaining: due}
    end)
  end

  defp recorded_funding(operation_rows, group_id) do
    operation_rows
    |> Enum.flat_map(fn [record_id, operation_id, operation_type, result_json] ->
      case Jason.decode(result_json) do
        {:ok, %{"status" => "applied", "group_id" => ^group_id, "amount_cents" => amount}}
        when operation_type in ["record_cash_payment", "apply_hotel_credit"] ->
          [
            %{
              kind: if(operation_type == "record_cash_payment", do: :cash, else: :credit),
              source: operation_id,
              amount: amount,
              record_id: record_id
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp sum_amount(funding, kind),
    do: Enum.reduce(funding, 0, &if(&1.kind == kind, do: &1.amount + &2, else: &2))

  defp split_credit_sources(rows, sources), do: split_credit_sources(rows, sources, [])

  defp split_credit_sources([], _sources, result), do: Enum.reverse(result)

  defp split_credit_sources([{lot_id, amount} | rows], [{source, available} | sources], result) do
    if available == 0 do
      split_credit_sources([{lot_id, amount} | rows], sources, result)
    else
      part = min(amount, available)
      rest_amount = amount - part
      rest_available = available - part
      result = if part > 0, do: [{source, lot_id, part} | result], else: result

      sources = if rest_available == 0, do: sources, else: [{source, rest_available} | sources]
      rows = if rest_amount == 0, do: rows, else: [{lot_id, rest_amount} | rows]
      split_credit_sources(rows, sources, result)
    end
  end

  defp split_credit_sources(_rows, [], result), do: Enum.reverse(result)

  defp allocate_events(events, rooms) do
    remaining = Map.new(rooms, &{&1.room_id, &1.remaining})

    Enum.reduce(events, {[], remaining}, fn event, {allocations, remaining} ->
      case event.kind do
        :cash ->
          {parts, remaining} = allocate_amount(rooms, remaining, event.amount)

          {allocations ++
             Enum.map(parts, &Map.merge(&1, %{kind: :cash, source: event.source})), remaining}

        :credit ->
          {allocations, remaining} =
            Enum.reduce(
              Enum.filter(events_credit_pieces(rooms, event), &(&1.amount > 0)),
              {allocations, remaining},
              fn piece, {allocations, remaining} ->
                {parts, remaining} = allocate_amount(rooms, remaining, piece.amount)

                {allocations ++
                   Enum.map(parts, fn part ->
                     Map.merge(part, %{
                       kind: :credit,
                       source: piece.source,
                       lot_id: piece.lot_id
                     })
                   end), remaining}
              end
            )

          {allocations, remaining}
      end
    end)
  end

  defp events_credit_pieces(_rooms, %{source: source, amount: amount, pieces: pieces}) do
    Enum.filter(pieces, fn {piece_source, _lot_id, _piece_amount} -> piece_source == source end)
    |> Enum.map(fn {_source, lot_id, piece_amount} ->
      %{source: source, lot_id: lot_id, amount: min(piece_amount, amount)}
    end)
  end

  defp events_credit_pieces(_rooms, _event), do: []

  defp allocate_amount(rooms, remaining, amount),
    do: allocate_amount(rooms, remaining, amount, [])

  defp allocate_amount(_rooms, remaining, amount, allocations) when amount <= 0,
    do: {Enum.reverse(allocations), remaining}

  defp allocate_amount([room | rooms], remaining, amount, allocations) do
    available = Map.get(remaining, room.room_id, 0)
    allocated = min(available, amount)

    if allocated > 0 do
      remaining = Map.put(remaining, room.room_id, available - allocated)
      allocation = %{room_id: room.room_id, amount: allocated}
      allocate_amount(rooms, remaining, amount - allocated, [allocation | allocations])
    else
      allocate_amount(rooms, remaining, amount, allocations)
    end
  end

  defp allocate_amount([], remaining, _amount, allocations),
    do: {Enum.reverse(allocations), remaining}

  defp room_deposit("advance_purchase", nightly_rate, nights), do: nightly_rate * nights

  defp room_deposit("flexible", nightly_rate, nights),
    do: div(nightly_rate * nights * 40 + 100, 200)

  defp room_deposit(_rate_plan, nightly_rate, nights), do: nightly_rate * nights

  defp credit_value(cash_cents), do: cash_cents + round_half_up(cash_cents * 10, 100)

  defp round_half_up(numerator, denominator),
    do: div(numerator * 2 + denominator, denominator * 2)
end
