defmodule GroupStay.Repo.Migrations.AddRoomPaymentAccounting do
  use Ecto.Migration

  def up do
    alter table(:group_rooms) do
      add :status, :text, null: false, default: "active"
      add :deposit_due_cents, :integer, null: false, default: 0
    end

    alter table(:group_credit_allocations) do
      add :room_id, references(:group_rooms, on_delete: :delete_all)
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:ledger_entries) do
      add :payment_operation_id, :text
    end

    create table(:group_cash_allocations) do
      add :group_id,
          references(:groups, column: :group_id, type: :text, on_delete: :delete_all),
          null: false

      add :room_id, references(:group_rooms, on_delete: :delete_all), null: false
      add :payment_operation_id, :text
      add :amount_cents, :integer, null: false
    end

    create index(:group_cash_allocations, [:group_id, :room_id])
    create index(:group_cash_allocations, [:payment_operation_id])
    create index(:group_credit_allocations, [:room_id])

    create table(:payment_credit_entitlements) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :payment_operation_id, :text
      add :amount_cents, :integer, null: false
    end

    create unique_index(:payment_credit_entitlements, [:credit_lot_id, :payment_operation_id])
    create index(:payment_credit_entitlements, [:payment_operation_id])

    flush()
    backfill_room_accounting()
  end

  def down do
    drop table(:payment_credit_entitlements)
    drop table(:group_cash_allocations)
    drop index(:group_credit_allocations, [:room_id])

    alter table(:ledger_entries) do
      remove :payment_operation_id
    end

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:group_credit_allocations) do
      remove :room_id
    end

    alter table(:group_rooms) do
      remove :deposit_due_cents
      remove :status
    end
  end

  defp backfill_room_accounting do
    groups =
      repo().query!(
        "SELECT group_id, guest_id, rate_plan, arrival_on, departure_on, status, cash_paid_cents, credit_paid_cents FROM groups ORDER BY group_id"
      ).rows

    durable_operations = load_durable_operations()

    Enum.each(groups, fn [
                           group_id,
                           _guest_id,
                           rate_plan,
                           arrival_on,
                           departure_on,
                           status,
                           cash_paid,
                           credit_paid
                         ] ->
      rooms =
        repo().query!(
          "SELECT id, room_id, nightly_rate_cents FROM group_rooms WHERE group_id = ? ORDER BY position",
          [group_id]
        ).rows

      room_data =
        Enum.map(rooms, fn [id, room_id, nightly_rate] ->
          nights = Date.diff(Date.from_iso8601!(departure_on), Date.from_iso8601!(arrival_on))
          lodging = nights * nightly_rate
          due = if rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging

          if status == "active" do
            repo().query!(
              "UPDATE group_rooms SET status = 'active', deposit_due_cents = ? WHERE id = ?",
              [due, id]
            )

            %{id: id, room_id: room_id, remaining: due}
          else
            repo().query!(
              "UPDATE group_rooms SET status = 'cancelled', deposit_due_cents = 0 WHERE id = ?",
              [id]
            )

            %{id: id, room_id: room_id, remaining: 0}
          end
        end)

      if status == "active" do
        operations =
          durable_operations
          |> Enum.filter(fn operation ->
            operation.result["group_id"] == group_id and operation.result["status"] == "applied" and
              operation.type in ["record_cash_payment", "apply_hotel_credit"]
          end)

        cash_operations =
          Enum.filter(operations, &(&1.type == "record_cash_payment"))
          |> Enum.map(&%{operation_id: &1.operation_id, amount: &1.result["amount_cents"]})

        credit_operations = Enum.filter(operations, &(&1.type == "apply_hotel_credit"))

        legacy_cash = max(cash_paid - Enum.reduce(cash_operations, 0, &(&1.amount + &2)), 0)

        old_credit_rows =
          repo().query!(
            "SELECT id, credit_lot_id, amount_cents FROM group_credit_allocations WHERE group_id = ? ORDER BY id",
            [group_id]
          ).rows

        durable_credit_total =
          Enum.reduce(credit_operations, 0, &((&1.result["amount_cents"] || 0) + &2))

        legacy_credit = max(credit_paid - durable_credit_total, 0)

        {legacy_credit_chunks, remaining_credit_rows} =
          take_credit_chunks(old_credit_rows, legacy_credit)

        {durable_credit_blocks, _unused_rows} =
          Enum.map_reduce(credit_operations, remaining_credit_rows, fn operation, rows ->
            {chunks, rest} = take_credit_chunks(rows, operation.result["amount_cents"] || 0)
            {{operation.operation_id, chunks}, rest}
          end)

        repo().query!("DELETE FROM group_credit_allocations WHERE group_id = ?", [group_id])

        {room_data, legacy_cash_chunks} =
          allocate_cash(room_data, legacy_cash, nil)

        insert_cash_chunks(group_id, legacy_cash_chunks)

        {room_data, legacy_credit_assignments} = allocate_credit(room_data, legacy_credit_chunks)

        insert_credit_chunks(group_id, legacy_credit_assignments)

        credit_blocks = Map.new(durable_credit_blocks)

        Enum.reduce(operations, room_data, fn operation, current_rooms ->
          amount = operation.result["amount_cents"] || 0

          case operation.type do
            "record_cash_payment" ->
              {updated_rooms, allocations} =
                allocate_cash(current_rooms, amount, operation.operation_id)

              insert_cash_chunks(group_id, allocations)
              updated_rooms

            "apply_hotel_credit" ->
              {updated_rooms, allocations} =
                allocate_credit(current_rooms, Map.get(credit_blocks, operation.operation_id, []))

              insert_credit_chunks(group_id, allocations)
              updated_rooms
          end
        end)
      end
    end)

    backfill_payment_ledger_entries(durable_operations)
    backfill_credit_entitlements(durable_operations)
  end

  defp load_durable_operations do
    repo().query!(
      "SELECT operation_id, operation_type, submitted_content, result FROM partner_operations ORDER BY rowid"
    ).rows
    |> Enum.map(fn [operation_id, type, content, result] ->
      %{
        operation_id: operation_id,
        type: type,
        content: decode_json(content),
        result: decode_json(result)
      }
    end)
  end

  defp decode_json(value) when is_map(value), do: value
  defp decode_json(value) when is_binary(value), do: Jason.decode!(value)

  defp take_credit_chunks(rows, amount), do: take_credit_chunks(rows, amount, [])
  defp take_credit_chunks(rows, 0, chunks), do: {Enum.reverse(chunks), rows}
  defp take_credit_chunks([], _amount, chunks), do: {Enum.reverse(chunks), []}

  defp take_credit_chunks([[id, lot_id, available] | rest], amount, chunks) do
    used = min(available, amount)
    next_chunks = if used > 0, do: [{lot_id, used} | chunks], else: chunks
    remaining_row = if available > used, do: [[id, lot_id, available - used] | rest], else: rest
    take_credit_chunks(remaining_row, amount - used, next_chunks)
  end

  defp allocate_cash(rooms, amount, payment_operation_id) do
    allocate_cash(rooms, amount, payment_operation_id, [])
  end

  defp allocate_cash(rooms, 0, _payment_operation_id, allocations),
    do: {rooms, Enum.reverse(allocations)}

  defp allocate_cash([], _amount, _payment_operation_id, allocations),
    do: {[], Enum.reverse(allocations)}

  defp allocate_cash([room | rest], amount, payment_operation_id, allocations) do
    used = min(room.remaining, amount)
    room = %{room | remaining: room.remaining - used}

    allocation =
      if used > 0,
        do: [
          %{room_id: room.id, payment_operation_id: payment_operation_id, amount: used}
          | allocations
        ],
        else: allocations

    {tail, rows} = allocate_cash(rest, amount - used, payment_operation_id, allocation)
    {[room | tail], rows}
  end

  defp allocate_credit(rooms, chunks) do
    Enum.reduce(chunks, {rooms, []}, fn {lot_id, amount}, {current_rooms, allocations} ->
      {updated_rooms, rows} = allocate_credit_lot(current_rooms, lot_id, amount, [])

      {updated_rooms, allocations ++ rows}
    end)
  end

  defp allocate_credit_lot(rooms, _lot_id, 0, allocations), do: {rooms, Enum.reverse(allocations)}
  defp allocate_credit_lot([], _lot_id, _amount, allocations), do: {[], Enum.reverse(allocations)}

  defp allocate_credit_lot([room | rest], lot_id, amount, allocations) do
    used = min(room.remaining, amount)
    room = %{room | remaining: room.remaining - used}

    allocation =
      if used > 0,
        do: [%{room_id: room.id, credit_lot_id: lot_id, amount: used} | allocations],
        else: allocations

    {tail, rows} = allocate_credit_lot(rest, lot_id, amount - used, allocation)
    {[room | tail], rows}
  end

  defp insert_cash_chunks(group_id, allocations) do
    Enum.each(allocations, fn allocation ->
      repo().query!(
        "INSERT INTO group_cash_allocations (group_id, room_id, payment_operation_id, amount_cents) VALUES (?, ?, ?, ?)",
        [group_id, allocation.room_id, allocation.payment_operation_id, allocation.amount]
      )
    end)
  end

  defp insert_credit_chunks(group_id, allocations) do
    Enum.each(allocations, fn allocation ->
      repo().query!(
        "INSERT INTO group_credit_allocations (group_id, credit_lot_id, room_id, amount_cents) VALUES (?, ?, ?, ?)",
        [group_id, allocation.credit_lot_id, allocation.room_id, allocation.amount]
      )
    end)
  end

  defp backfill_payment_ledger_entries(operations) do
    groups =
      Enum.map(operations, & &1.result["group_id"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Enum.each(groups, fn group_id ->
      payment_operations =
        Enum.filter(operations, fn operation ->
          operation.type == "record_cash_payment" and operation.result["group_id"] == group_id and
            operation.result["status"] == "applied"
        end)

      held_entries =
        repo().query!(
          "SELECT id, amount_cents, occurred_on, entry_type FROM ledger_entries WHERE group_id = ? AND entry_type = 'cash_held' AND payment_operation_id IS NULL ORDER BY id",
          [group_id]
        ).rows

      durable_amount =
        Enum.reduce(payment_operations, 0, fn op, total ->
          total + (op.result["amount_cents"] || 0)
        end)

      recorded_amount = total_rows(held_entries)

      sources = [
        {nil, max(recorded_amount - durable_amount, 0)}
        | Enum.map(payment_operations, &{&1.operation_id, &1.result["amount_cents"] || 0})
      ]

      tag_ledger_rows(group_id, held_entries, sources)

      disposition_rows =
        repo().query!(
          "SELECT id, amount_cents, occurred_on, entry_type FROM ledger_entries WHERE group_id = ? AND entry_type IN ('cash_refunded', 'cash_retained', 'cash_converted_to_credit') AND payment_operation_id IS NULL ORDER BY id",
          [group_id]
        ).rows

      tag_ledger_rows(group_id, disposition_rows, sources)
    end)
  end

  defp tag_ledger_rows(_group_id, [], _sources), do: :ok

  defp tag_ledger_rows(group_id, [[id, amount, occurred_on, type] | rows], sources) do
    {parts, remaining_sources} = take_source_amount(sources, amount, [])

    case parts do
      [{payment_id, _part_amount}] ->
        repo().query!("UPDATE ledger_entries SET payment_operation_id = ? WHERE id = ?", [
          payment_id,
          id
        ])

      [{payment_id, first_amount} | additional_parts] ->
        repo().query!(
          "UPDATE ledger_entries SET amount_cents = ?, payment_operation_id = ? WHERE id = ?",
          [first_amount, payment_id, id]
        )

        Enum.each(additional_parts, fn {part_payment_id, part_amount} ->
          repo().query!(
            "INSERT INTO ledger_entries (group_id, payment_operation_id, entry_type, amount_cents, occurred_on) VALUES (?, ?, ?, ?, ?)",
            [group_id, part_payment_id, type, part_amount, occurred_on]
          )
        end)

      [] ->
        :ok
    end

    tag_ledger_rows(group_id, rows, remaining_sources)
  end

  defp take_source_amount(sources, 0, parts), do: {Enum.reverse(parts), sources}
  defp take_source_amount([], _amount, parts), do: {Enum.reverse(parts), []}

  defp take_source_amount([{payment_id, available} | rest], amount, parts) do
    used = min(available, amount)
    next_parts = if used > 0, do: [{payment_id, used} | parts], else: parts
    next_sources = if available > used, do: [{payment_id, available - used} | rest], else: rest
    take_source_amount(next_sources, amount - used, next_parts)
  end

  defp total_rows(rows),
    do: Enum.reduce(rows, 0, fn [_id, amount | _], total -> total + amount end)

  defp backfill_credit_entitlements(operations) do
    cancellations =
      Enum.filter(operations, fn operation ->
        operation.type == "cancel_group" and operation.result["status"] == "applied" and
          (operation.result["credit_issued_cents"] || 0) > 0
      end)

    Enum.each(cancellations, fn cancellation ->
      lot =
        repo().query!(
          "SELECT id FROM credit_lots WHERE source_operation_id = ? LIMIT 1",
          [cancellation.operation_id]
        ).rows
        |> List.first()

      if lot do
        [lot_id] = lot
        group_id = cancellation.result["group_id"]

        converted_rows =
          repo().query!(
            "SELECT payment_operation_id, SUM(amount_cents) FROM ledger_entries WHERE group_id = ? AND entry_type = 'cash_converted_to_credit' GROUP BY payment_operation_id",
            [group_id]
          ).rows

        converted_by_payment = Map.new(converted_rows)
        legacy_principal = Map.get(converted_by_payment, nil, 0) || 0

        durable_payment_order =
          operations
          |> Enum.filter(fn operation ->
            operation.type == "record_cash_payment" and operation.result["group_id"] == group_id and
              operation.result["status"] == "applied"
          end)

        contributions =
          Enum.map(durable_payment_order, fn payment ->
            {payment.operation_id, Map.get(converted_by_payment, payment.operation_id, 0) || 0}
          end)

        Enum.reduce([{nil, legacy_principal} | contributions], {0, 0}, fn {payment_id, principal},
                                                                          {running_principal,
                                                                           previous_bonus} ->
          next_principal = running_principal + principal
          next_bonus = div(next_principal + 5, 10)
          entitlement = principal + next_bonus - previous_bonus

          if is_binary(payment_id) and entitlement > 0 do
            repo().query!(
              "INSERT INTO payment_credit_entitlements (credit_lot_id, payment_operation_id, amount_cents) VALUES (?, ?, ?)",
              [lot_id, payment_id, entitlement]
            )
          end

          {next_principal, next_bonus}
        end)
      end
    end)
  end
end
