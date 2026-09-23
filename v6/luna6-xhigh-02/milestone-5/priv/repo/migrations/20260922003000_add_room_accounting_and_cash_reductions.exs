defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndCashReductions do
  use Ecto.Migration

  def up do
    alter table(:group_rooms) do
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :deposit_paid_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
      add :status, :text, null: false, default: "active"
    end

    alter table(:group_credit_allocations) do
      add :room_id, :text
      add :source_operation_id, :text
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:cash_payments, primary_key: false) do
      add :payment_operation_id, :text, primary_key: true
      add :group_id, references(:groups, column: :group_id, type: :text), null: false
      add :recorded_cents, :integer, null: false
      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create index(:cash_payments, [:group_id])

    create table(:room_cash_allocations) do
      add :group_id, references(:groups, column: :group_id, type: :text), null: false
      add :room_id, :text, null: false
      add :payment_operation_id, :text
      add :amount_cents, :integer, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:room_cash_allocations, [:group_id, :room_id])
    create index(:room_cash_allocations, [:payment_operation_id])

    create table(:credit_lot_entitlements) do
      add :credit_lot_id, references(:credit_lots, on_delete: :restrict), null: false
      add :payment_operation_id, :text
      add :amount_cents, :integer, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:credit_lot_entitlements, [:payment_operation_id])

    flush()
    backfill_existing_data()
  end

  def down do
    drop table(:credit_lot_entitlements)
    drop table(:room_cash_allocations)
    drop table(:cash_payments)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:group_credit_allocations) do
      remove :source_operation_id
      remove :room_id
    end

    alter table(:group_rooms) do
      remove :status
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :deposit_paid_cents
      remove :deposit_due_cents
      remove :lodging_total_cents
    end
  end

  defp backfill_existing_data do
    groups =
      query!(
        "SELECT group_id, rate_plan, arrival_on, departure_on, status, lodging_total_cents, deposit_due_cents, cash_paid_cents, credit_paid_cents FROM groups"
      )

    room_rows =
      query!(
        "SELECT id, group_id, room_id, nightly_rate_cents, position FROM group_rooms ORDER BY group_id, position, id"
      )

    operation_rows =
      query!(
        "SELECT id, operation_id, operation_type, submission, result FROM operation_records ORDER BY id"
      )

    entry_rows =
      query!(
        "SELECT id, group_id, kind, amount_cents, operation_id FROM ledger_entries ORDER BY id"
      )

    allocation_rows =
      query!(
        "SELECT id, group_id, credit_lot_id, amount_cents FROM group_credit_allocations ORDER BY id"
      )

    operations = Enum.map(operation_rows, &decode_operation/1)

    groups
    |> Enum.each(fn [
                      group_id,
                      rate_plan,
                      arrival_on,
                      departure_on,
                      status,
                      _lodging,
                      _due,
                      cash_paid,
                      credit_paid
                    ] ->
      rooms =
        room_rows
        |> Enum.filter(fn [_id, room_group_id | _] -> room_group_id == group_id end)
        |> Enum.map(fn [id, _group_id, room_id, nightly_rate, position] ->
          nights = Date.diff(parse_date(departure_on), parse_date(arrival_on))
          lodging = nights * nightly_rate

          due =
            if rate_plan == "advance_purchase",
              do: lodging,
              else: div(lodging * 20 + 50, 100)

          attrs = %{
            id: id,
            room_id: room_id,
            position: position,
            lodging: lodging,
            due: due,
            status: if(status == "active", do: "active", else: "cancelled"),
            paid: 0,
            cash: 0,
            credit: 0
          }

          query!(
            "UPDATE group_rooms SET lodging_total_cents = ?, deposit_due_cents = ?, status = ? WHERE id = ?",
            [lodging, due, attrs.status, id]
          )

          attrs
        end)

      group_entries =
        Enum.filter(entry_rows, fn [_id, entry_group_id | _] -> entry_group_id == group_id end)

      applied_ops =
        Enum.filter(operations, fn op ->
          op.result["status"] == "applied" and op.result["group_id"] == group_id and
            op.operation_type in ["record_cash_payment", "apply_hotel_credit"]
        end)

      payment_ops = Enum.filter(applied_ops, &(&1.operation_type == "record_cash_payment"))
      credit_ops = Enum.filter(applied_ops, &(&1.operation_type == "apply_hotel_credit"))

      payment_amounts =
        Enum.map(payment_ops, fn op ->
          amount =
            group_entries
            |> Enum.find_value(0, fn [_id, _gid, kind, cents, op_id] ->
              if kind == "payment" and op_id == op.operation_id, do: cents
            end)

          {op.operation_id, amount}
        end)

      recorded_payment_total =
        Enum.reduce(payment_amounts, 0, fn {_id, cents}, sum -> sum + cents end)

      legacy_cash = max(cash_paid - recorded_payment_total, 0)

      payment_sources = [{nil, legacy_cash} | payment_amounts]

      if status == "active" do
        credit_allocations =
          Enum.filter(allocation_rows, fn [_id, allocation_group_id | _] ->
            allocation_group_id == group_id
          end)

        credit_total =
          Enum.reduce(credit_allocations, 0, fn [_id, _gid, _lot, cents], sum -> sum + cents end)

        recorded_credit_total =
          Enum.reduce(credit_ops, 0, fn op, sum -> sum + (op.result["amount_cents"] || 0) end)

        legacy_credit = max(credit_paid - recorded_credit_total, 0)

        credit_segments = [
          {nil, legacy_credit}
          | Enum.map(credit_ops, &{&1.operation_id, &1.result["amount_cents"] || 0})
        ]

        sourced_credit_allocations = source_credit_rows(credit_allocations, credit_segments)
        repo().query!("DELETE FROM group_credit_allocations WHERE group_id = ?", [group_id])

        {rooms, _} = migrate_cash_funding(rooms, legacy_cash, nil, group_id)

        {rooms, _} =
          sourced_credit_allocations
          |> Enum.filter(fn {_lot_id, source_id, _amount} -> is_nil(source_id) end)
          |> Enum.reduce({rooms, credit_total}, fn {lot_id, source_id, amount}, {room_state, _} ->
            {next, _} = migrate_credit_funding(room_state, amount, group_id, lot_id, source_id)
            {next, 0}
          end)

        {rooms, _} =
          Enum.reduce(applied_ops, {rooms, 0}, fn op, {room_state, _} ->
            if op.operation_type == "record_cash_payment" do
              amount = Map.new(payment_amounts) |> Map.get(op.operation_id, 0)
              {next, _} = migrate_cash_funding(room_state, amount, op.operation_id, group_id)
              {next, 0}
            else
              {next, _} =
                sourced_credit_allocations
                |> Enum.filter(fn {_lot_id, source_id, _amount} ->
                  source_id == op.operation_id
                end)
                |> Enum.reduce({room_state, 0}, fn {lot_id, source_id, amount}, {state, _} ->
                  {new_state, _} =
                    migrate_credit_funding(state, amount, group_id, lot_id, source_id)

                  {new_state, 0}
                end)

              {next, 0}
            end
          end)

        update_room_and_group_totals(group_id, rooms)
      else
        repo().query!("DELETE FROM group_credit_allocations WHERE group_id = ?", [group_id])

        query!(
          "UPDATE groups SET lodging_total_cents = 0, deposit_due_cents = 0, deposit_paid_cents = 0, cash_paid_cents = 0, credit_paid_cents = 0 WHERE group_id = ?",
          [group_id]
        )
      end

      payment_dispositions =
        legacy_and_payment_dispositions(payment_sources, status, group_entries)

      Enum.each(payment_amounts, fn {payment_id, amount} ->
        disposition = Map.get(payment_dispositions, payment_id, %{})

        query!(
          "INSERT INTO cash_payments (payment_operation_id, group_id, recorded_cents, held_cents, refunded_cents, retained_cents, converted_to_credit_cents, reduced_cents, charged_back_cents, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
          [
            payment_id,
            group_id,
            amount,
            Map.get(disposition, :held, 0),
            Map.get(disposition, :refunded, 0),
            Map.get(disposition, :retained, 0),
            Map.get(disposition, :converted, 0)
          ]
        )
      end)

      backfill_credit_entitlements(group_id, payment_sources, group_entries)
    end)

    repo().query!(
      "UPDATE group_credit_allocations SET room_id = (SELECT room_id FROM group_rooms WHERE group_rooms.group_id = group_credit_allocations.group_id ORDER BY position, id LIMIT 1) WHERE room_id IS NULL"
    )
  end

  defp migrate_cash_funding(rooms, amount, source_id, group_id) do
    {next, chunks, left} = allocate_rooms(rooms, amount, :cash)

    Enum.each(chunks, fn {room, cents} ->
      insert_cash_allocation(group_id, room.room_id, source_id, cents)
    end)

    {next, left}
  end

  defp migrate_credit_funding(rooms, amount, group_id, lot_id, source_id) do
    {next, chunks, left} = allocate_rooms(rooms, amount, :credit)

    Enum.each(chunks, fn {room, cents} ->
      insert_credit_allocation(group_id, room.room_id, lot_id, source_id, cents)
    end)

    {next, left}
  end

  defp legacy_and_payment_dispositions(sources, "active", _entries) do
    sources
    |> Enum.reject(fn {id, _} -> is_nil(id) end)
    |> Map.new(fn {id, amount} -> {id, %{held: amount}} end)
  end

  defp legacy_and_payment_dispositions(sources, _status, entries) do
    buckets = %{
      refunded: sum_kind(entries, "refund"),
      retained: sum_kind(entries, "retention"),
      converted: sum_kind(entries, "cash_to_credit")
    }

    Enum.reduce(sources, {%{}, buckets}, fn {source_id, amount}, {result, remaining} ->
      {disposition, remaining} =
        consume_dispositions(amount, remaining, [:refunded, :retained, :converted])

      result = if is_nil(source_id), do: result, else: Map.put(result, source_id, disposition)
      {result, remaining}
    end)
    |> elem(0)
  end

  defp consume_dispositions(_amount, buckets, []), do: {%{}, buckets}

  defp consume_dispositions(amount, buckets, [key | rest]) do
    take = min(amount, Map.get(buckets, key, 0))

    {later, buckets} =
      consume_dispositions(
        amount - take,
        Map.put(buckets, key, Map.get(buckets, key, 0) - take),
        rest
      )

    {if(take > 0, do: Map.put(later, key, take), else: later), buckets}
  end

  defp backfill_credit_entitlements(_group_id, sources, entries) do
    entries
    |> Enum.filter(fn [_id, _gid, kind, _amount, _op_id] -> kind == "cash_to_credit" end)
    |> Enum.each(fn [_id, _gid, _kind, converted, operation_id] ->
      case repo().query!("SELECT id FROM credit_lots WHERE source_operation_id = ?", [
             operation_id
           ]).rows do
        [[lot_id] | _] ->
          {entitlements, _remaining, _running} =
            Enum.reduce(sources, {[], converted, 0}, fn {payment_id, source_amount},
                                                        {rows, remaining, running} ->
              used = min(source_amount, remaining)
              entitlement = bonus(running + used) - bonus(running)
              rows = if used > 0, do: [{payment_id, entitlement} | rows], else: rows
              {rows, remaining - used, running + used}
            end)

          Enum.each(entitlements, fn {payment_id, cents} ->
            query!(
              "INSERT INTO credit_lot_entitlements (credit_lot_id, payment_operation_id, amount_cents, inserted_at, updated_at) VALUES (?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
              [lot_id, payment_id, cents]
            )
          end)

        _ ->
          :ok
      end
    end)
  end

  defp source_credit_rows(rows, segments) do
    segments = Enum.map(segments, fn {id, amount} -> {id, amount} end)

    {result, remaining_segments} =
      Enum.reduce(rows, {[], segments}, fn [_id, _group_id, lot_id, row_amount], {acc, sources} ->
        {chunks, sources} = take_source_chunks(row_amount, sources, [])

        {acc ++ Enum.map(chunks, fn {source_id, cents} -> {lot_id, source_id, cents} end),
         sources}
      end)

    _ = remaining_segments
    result
  end

  defp take_source_chunks(0, sources, acc), do: {acc, sources}
  defp take_source_chunks(_amount, [], acc), do: {acc, []}

  defp take_source_chunks(amount, [{source_id, available} | rest], acc) do
    if available == 0 do
      take_source_chunks(amount, rest, acc)
    else
      taken = min(amount, available)
      next_acc = if taken > 0, do: acc ++ [{source_id, taken}], else: acc

      next_sources =
        if taken == available, do: rest, else: [{source_id, available - taken} | rest]

      take_source_chunks(amount - taken, next_sources, next_acc)
    end
  end

  defp allocate_rooms(rooms, amount, type) do
    {rooms, chunks, left} =
      Enum.reduce_while(rooms, {[], [], amount}, fn room, {done, chunks, left} ->
        capacity = max(room.due - room.paid, 0)
        take = min(capacity, left)

        updated =
          room
          |> Map.update!(:paid, &(&1 + take))
          |> Map.update!(type, &(&1 + take))

        chunks = if take > 0, do: chunks ++ [{room, take}], else: chunks
        state = {done ++ [updated], chunks, left - take}

        if elem(state, 2) == 0,
          do: {:halt, {done ++ [updated] ++ Enum.drop(rooms, length(done) + 1), chunks, 0}},
          else: {:cont, state}
      end)

    {rooms, chunks, left}
  end

  defp update_room_and_group_totals(group_id, rooms) do
    Enum.each(rooms, fn room ->
      query!(
        "UPDATE group_rooms SET deposit_paid_cents = ?, cash_paid_cents = ?, credit_paid_cents = ? WHERE id = ?",
        [room.paid, room.cash, room.credit, room.id]
      )
    end)

    lodging = Enum.reduce(rooms, 0, &(&1.lodging + &2))
    due = Enum.reduce(rooms, 0, &(&1.due + &2))
    paid = Enum.reduce(rooms, 0, &(&1.paid + &2))
    cash = Enum.reduce(rooms, 0, &(&1.cash + &2))
    credit = Enum.reduce(rooms, 0, &(&1.credit + &2))

    query!(
      "UPDATE groups SET lodging_total_cents = ?, deposit_due_cents = ?, deposit_paid_cents = ?, cash_paid_cents = ?, credit_paid_cents = ? WHERE group_id = ?",
      [lodging, due, paid, cash, credit, group_id]
    )
  end

  defp insert_cash_allocation(_group_id, _room_id, _source, cents) when cents <= 0, do: :ok

  defp insert_cash_allocation(group_id, room_id, source, cents) do
    query!(
      "INSERT INTO room_cash_allocations (group_id, room_id, payment_operation_id, amount_cents, inserted_at, updated_at) VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
      [group_id, room_id, source, cents]
    )
  end

  defp insert_credit_allocation(_group_id, _room_id, _lot, _source, cents) when cents <= 0,
    do: :ok

  defp insert_credit_allocation(group_id, room_id, lot_id, source, cents) do
    query!(
      "INSERT INTO group_credit_allocations (group_id, credit_lot_id, amount_cents, room_id, source_operation_id, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
      [group_id, lot_id, cents, room_id, source]
    )
  end

  defp decode_operation([id, operation_id, operation_type, submission, result]) do
    %{
      id: id,
      operation_id: operation_id,
      operation_type: operation_type,
      submission: decode_json(submission),
      result: decode_json(result)
    }
  end

  defp decode_json(value) when is_map(value), do: value
  defp decode_json(value) when is_binary(value), do: Jason.decode!(value)
  defp decode_json(_), do: %{}

  defp sum_kind(entries, kind) do
    Enum.reduce(entries, 0, fn [_id, _gid, entry_kind, cents, _op_id], sum ->
      if entry_kind == kind, do: sum + cents, else: sum
    end)
  end

  defp parse_date(%Date{} = date), do: date
  defp parse_date(value) when is_binary(value), do: Date.from_iso8601!(value)
  defp parse_date(value), do: value |> to_string() |> Date.from_iso8601!()

  defp bonus(cents), do: cents + div(cents * 10 + 50, 100)

  defp query!(sql, params \\ []), do: repo().query!(sql, params).rows
end
