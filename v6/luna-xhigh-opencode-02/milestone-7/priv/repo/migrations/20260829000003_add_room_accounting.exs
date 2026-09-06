defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :lodging_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :status, :string, null: false, default: "active"
    end

    alter table(:credit_allocations) do
      add :room_id, :integer
      add :operation_id, :string
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:cash_allocations) do
      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :delete_all),
          null: false

      add :room_id,
          references(:rooms, on_delete: :delete_all),
          null: false

      add :payment_operation_id, :string
      add :original_cents, :integer, null: false
      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
    end

    create table(:credit_lot_contributions) do
      add :credit_lot_id,
          references(:credit_lots, on_delete: :delete_all),
          null: false

      add :payment_operation_id, :string
      add :entitlement_cents, :integer, null: false
    end

    create index(:cash_allocations, [:group_id, :room_id])
    create index(:cash_allocations, [:payment_operation_id])
    create index(:credit_allocations, [:group_id, :room_id])
    create index(:credit_allocations, [:operation_id])
    create index(:credit_lot_contributions, [:payment_operation_id])
    create index(:credit_lot_contributions, [:credit_lot_id])

    flush()
    backfill_rooms_and_funding()
  end

  def down do
    drop index(:credit_lot_contributions, [:credit_lot_id])
    drop index(:credit_lot_contributions, [:payment_operation_id])
    drop table(:credit_lot_contributions)
    drop index(:credit_allocations, [:operation_id])
    drop index(:credit_allocations, [:group_id, :room_id])
    drop index(:cash_allocations, [:payment_operation_id])
    drop index(:cash_allocations, [:group_id, :room_id])
    drop table(:cash_allocations)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:credit_allocations) do
      remove :operation_id
      remove :room_id
    end

    alter table(:rooms) do
      remove :status
      remove :deposit_due_cents
      remove :lodging_cents
    end
  end

  defp backfill_rooms_and_funding do
    groups =
      repo().query!("""
      SELECT group_id, rate_plan, arrival_on, departure_on,
             cash_paid_cents, credit_paid_cents, status,
             cash_refunded_cents, cash_retained_cents, cash_converted_to_credit_cents
      FROM groups
      """).rows

    Enum.each(groups, fn [
                           group_id,
                           rate_plan,
                           arrival_on,
                           departure_on,
                           cash_paid,
                           credit_paid,
                           group_status,
                           refunded,
                           retained,
                           converted
                         ] ->
      rooms =
        repo().query!(
          """
          SELECT id, nightly_rate_cents
          FROM rooms
          WHERE group_id = ?
          ORDER BY position, id
          """,
          [group_id]
        ).rows
        |> Enum.map(fn [id, nightly_rate] ->
          lodging =
            Date.diff(Date.from_iso8601!(departure_on), Date.from_iso8601!(arrival_on)) *
              nightly_rate

          deposit =
            if rate_plan == "advance_purchase", do: lodging, else: half_up(lodging * 20, 100)

          repo().query!(
            """
            UPDATE rooms
            SET lodging_cents = ?, deposit_due_cents = ?, status = ?
            WHERE id = ?
            """,
            [lodging, deposit, group_status, id]
          )

          %{id: id, deposit: deposit, cash_used: 0, credit_used: 0}
        end)

      recorded_cash = recorded_funding(group_id, "record_cash_payment")
      recorded_credit = recorded_funding(group_id, "apply_hotel_credit")
      legacy_cash = funding_remainder(cash_paid || 0, recorded_cash, group_id, "cash")
      legacy_credit = funding_remainder(credit_paid || 0, recorded_credit, group_id, "credit")

      old_credit_rows =
        repo().query!(
          """
          SELECT credit_lot_id, amount_cents
          FROM credit_allocations
          WHERE group_id = ?
          ORDER BY id
          """,
          [group_id]
        ).rows

      repo().query!("DELETE FROM credit_allocations WHERE group_id = ?", [group_id])

      {rooms, legacy_cash_chunks, remainder} = allocate_cash(rooms, legacy_cash, nil)
      ensure_allocated!(remainder, group_id, "legacy cash")
      cash_chunks = legacy_cash_chunks

      credit_stream =
        Enum.map(old_credit_rows, fn [lot_id, amount] -> %{lot_id: lot_id, amount: amount} end)

      {rooms, legacy_credit_chunks, credit_stream} =
        if group_status == "active" do
          {rooms, chunks, stream, remainder} =
            allocate_credit(rooms, credit_stream, legacy_credit, nil, group_id)

          ensure_allocated!(remainder, group_id, "legacy credit")
          {rooms, chunks, stream}
        else
          {rooms, [], credit_stream}
        end

      credit_chunks = legacy_credit_chunks

      {_rooms, credit_stream, cash_chunks, credit_chunks} =
        Enum.reduce(
          recorded_funding_in_order(group_id),
          {rooms, credit_stream, cash_chunks, credit_chunks},
          fn
            %{type: "record_cash_payment", operation_id: operation_id, amount: amount},
            {rooms, stream, cash_chunks, credit_chunks} ->
              {rooms, chunks, remainder} = allocate_cash(rooms, amount, operation_id)
              ensure_allocated!(remainder, group_id, "recorded cash")
              {rooms, stream, cash_chunks ++ chunks, credit_chunks}

            %{type: "apply_hotel_credit", operation_id: operation_id, amount: amount},
            {rooms, stream, cash_chunks, credit_chunks} ->
              if group_status == "active" do
                {rooms, chunks, stream, remainder} =
                  allocate_credit(rooms, stream, amount, operation_id, group_id)

                ensure_allocated!(remainder, group_id, "recorded credit")
                {rooms, stream, cash_chunks, credit_chunks ++ chunks}
              else
                {rooms, stream, cash_chunks, credit_chunks}
              end
          end
        )

      if group_status == "active" and credit_stream != [] do
        raise "could not allocate all existing credit for #{group_id}"
      end

      insert_cash_chunks(
        group_id,
        cash_chunks,
        group_status,
        refunded || 0,
        retained || 0,
        converted || 0
      )

      insert_credit_chunks(group_id, credit_chunks)
    end)

    backfill_credit_contributions()
  end

  defp backfill_credit_contributions do
    repo().query!("SELECT id, source_operation_id FROM credit_lots").rows
    |> Enum.each(fn [lot_id, source_operation_id] ->
      case repo().query!(
             """
             SELECT json_extract(payload, '$.group_id')
             FROM operations
             WHERE operation_id = ?
             """,
             [source_operation_id]
           ).rows do
        [[group_id]] when is_binary(group_id) ->
          case repo().query!(
                 """
                 SELECT cash_paid_cents, cash_converted_to_credit_cents
                 FROM groups
                 WHERE group_id = ?
                 """,
                 [group_id]
               ).rows do
            [[cash_paid, converted]] ->
              if (converted || 0) > 0 do
                payments = recorded_funding(group_id, "record_cash_payment")
                legacy = funding_remainder(cash_paid || 0, payments, group_id, "cash")
                settled_cash = min(converted, cash_paid || 0)
                legacy_settled = min(legacy, settled_cash)

                {_running, _remaining, contributions} =
                  Enum.reduce(
                    [%{operation_id: nil, amount: legacy_settled} | payments],
                    {0, settled_cash - legacy_settled, []},
                    fn payment, {running, remaining, contributions} ->
                      amount = min(payment.amount, max(remaining, 0))
                      next_running = running + amount

                      entitlement = bonus_value(next_running) - bonus_value(running)

                      contributions =
                        if entitlement > 0,
                          do: contributions ++ [{payment.operation_id, entitlement}],
                          else: contributions

                      {next_running, remaining - amount, contributions}
                    end
                  )

                Enum.each(contributions, fn {operation_id, entitlement} ->
                  repo().insert_all("credit_lot_contributions", [
                    %{
                      credit_lot_id: lot_id,
                      payment_operation_id: operation_id,
                      entitlement_cents: entitlement
                    }
                  ])
                end)

                :ok
              else
                :ok
              end

            _ ->
              :ok
          end

        _ ->
          :ok
      end
    end)
  end

  defp recorded_funding(group_id, type) do
    repo().query!(
      """
      SELECT operation_id, CAST(json_extract(result, '$.amount_cents') AS INTEGER)
      FROM operations
      WHERE type = ?
        AND json_extract(result, '$.status') = 'applied'
        AND json_extract(result, '$.group_id') = ?
      ORDER BY id
      """,
      [type, group_id]
    ).rows
    |> Enum.map(fn [operation_id, amount] ->
      %{operation_id: operation_id, amount: amount || 0, type: type}
    end)
  end

  defp recorded_funding_in_order(group_id) do
    # Operation ids are not chronological; the durable row id is the commit order.
    repo().query!(
      """
      SELECT operation_id, type, CAST(json_extract(result, '$.amount_cents') AS INTEGER)
      FROM operations
      WHERE type IN ('record_cash_payment', 'apply_hotel_credit')
        AND json_extract(result, '$.status') = 'applied'
        AND json_extract(result, '$.group_id') = ?
      ORDER BY id
      """,
      [group_id]
    ).rows
    |> Enum.map(fn [operation_id, type, amount] ->
      %{operation_id: operation_id, type: type, amount: amount || 0}
    end)
  end

  defp allocate_cash(rooms, amount, operation_id) do
    {rooms, chunks, remaining} =
      allocate_room_amount(
        rooms,
        amount,
        fn room_id, take ->
          %{room_id: room_id, amount: take, operation_id: operation_id}
        end,
        :cash
      )

    {rooms, chunks, remaining}
  end

  defp allocate_credit(rooms, stream, amount, operation_id, _group_id) do
    {rooms, chunks, stream, remaining} =
      take_credit_stream(rooms, stream, amount, operation_id, [])

    {rooms, chunks, stream, remaining}
  end

  defp take_credit_stream(rooms, stream, amount, operation_id, chunks) do
    if amount <= 0 or stream == [] do
      {rooms, chunks, stream, amount}
    else
      [row | rest] = stream
      take = min(amount, row.amount)

      {rooms, row_chunks, remaining_after} =
        allocate_room_amount(
          rooms,
          take,
          fn room_id, room_take ->
            %{room_id: room_id, lot_id: row.lot_id, amount: room_take, operation_id: operation_id}
          end,
          :credit
        )

      used = take - remaining_after

      remaining_row = row.amount - used
      stream = if remaining_row > 0, do: [%{row | amount: remaining_row} | rest], else: rest
      take_credit_stream(rooms, stream, amount - used, operation_id, chunks ++ row_chunks)
    end
  end

  defp allocate_room_amount(rooms, amount, make_chunk, kind) do
    Enum.reduce(rooms, {rooms, [], amount}, fn room, {rooms, chunks, remaining} ->
      capacity = room.deposit - room.cash_used - room.credit_used
      take = min(max(remaining, 0), max(capacity, 0))

      if take > 0 do
        room =
          case kind do
            :cash -> %{room | cash_used: room.cash_used + take}
            :credit -> %{room | credit_used: room.credit_used + take}
          end

        rooms =
          Enum.map(rooms, fn current -> if current.id == room.id, do: room, else: current end)

        {rooms, chunks ++ [make_chunk.(room.id, take)], remaining - take}
      else
        {rooms, chunks, remaining}
      end
    end)
  end

  defp insert_cash_chunks(group_id, chunks, group_status, refunded, retained, converted) do
    if group_status != "active" and refunded + retained + converted != sum_chunks(chunks) do
      raise "cash dispositions do not balance for #{group_id}"
    end

    chunks =
      if group_status == "active",
        do: Enum.map(chunks, &Map.put(&1, :disposition, :held)),
        else: settle_chunks(chunks, refunded, retained, converted)

    repo().insert_all(
      "cash_allocations",
      Enum.map(chunks, fn chunk ->
        {held, part_refunded, part_retained, part_converted} =
          case chunk.disposition do
            :held -> {chunk.amount, 0, 0, 0}
            :refunded -> {0, chunk.amount, 0, 0}
            :retained -> {0, 0, chunk.amount, 0}
            :converted -> {0, 0, 0, chunk.amount}
          end

        %{
          group_id: group_id,
          room_id: chunk.room_id,
          payment_operation_id: chunk.operation_id,
          original_cents: chunk.amount,
          held_cents: held,
          refunded_cents: part_refunded,
          retained_cents: part_retained,
          converted_to_credit_cents: part_converted,
          reduced_cents: 0,
          charged_back_cents: 0
        }
      end)
    )
  end

  defp settle_chunks(chunks, refunded, retained, converted) do
    {chunks, _remaining} =
      Enum.reduce(
        chunks,
        {[], %{refunded: refunded, retained: retained, converted: converted}},
        fn chunk, {settled, remaining} ->
          {parts, remaining} =
            Enum.reduce([:refunded, :retained, :converted], {[], remaining}, fn disposition,
                                                                                {parts, remaining} ->
              take =
                min(
                  chunk.amount - Enum.sum(Enum.map(parts, & &1.amount)),
                  Map.get(remaining, disposition)
                )

              if take > 0 do
                {parts ++ [%{chunk | amount: take, disposition: disposition}],
                 Map.update!(remaining, disposition, &(&1 - take))}
              else
                {parts, remaining}
              end
            end)

          used = Enum.sum(Enum.map(parts, & &1.amount))

          parts =
            if used < chunk.amount,
              do: parts ++ [%{chunk | amount: chunk.amount - used, disposition: :held}],
              else: parts

          {settled ++ parts, remaining}
        end
      )

    chunks
  end

  defp insert_credit_chunks(group_id, chunks) do
    repo().insert_all(
      "credit_allocations",
      Enum.map(chunks, fn chunk ->
        %{
          group_id: group_id,
          room_id: chunk.room_id,
          credit_lot_id: chunk.lot_id,
          amount_cents: chunk.amount,
          operation_id: chunk.operation_id
        }
      end)
    )
  end

  defp sum_funding(funding), do: Enum.sum(Enum.map(funding, & &1.amount))
  defp sum_chunks(chunks), do: Enum.sum(Enum.map(chunks, & &1.amount))

  defp funding_remainder(total, funding, group_id, kind) do
    remainder = total - sum_funding(funding)

    if remainder < 0 do
      raise "recorded #{kind} exceeds aggregate funding for #{group_id}"
    end

    remainder
  end

  defp ensure_allocated!(0, _group_id, _kind), do: :ok

  defp ensure_allocated!(remainder, group_id, kind) do
    raise "could not allocate #{remainder} cents of #{kind} for #{group_id}"
  end

  defp half_up(numerator, denominator), do: div(numerator + div(denominator, 2), denominator)
  defp bonus_value(cash), do: cash + half_up(cash * 10, 100)
end
