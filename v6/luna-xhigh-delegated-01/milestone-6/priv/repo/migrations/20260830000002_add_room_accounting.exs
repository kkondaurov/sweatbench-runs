defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    alter table(:hotel_credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:ledger_totals) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
      add :credit_shortfall_cents, :integer, null: false, default: 0
    end

    flush()

    create table(:cash_payments, primary_key: false) do
      add :operation_id, :string, primary_key: true, null: false

      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :delete_all),
          null: false

      add :recorded_cents, :integer, null: false
      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
    end

    create index(:cash_payments, [:group_id])

    create table(:room_allocations) do
      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :delete_all),
          null: false

      add :room_id, :string, null: false
      add :funding_type, :string, null: false
      add :operation_id, :string
      add :amount_cents, :integer, null: false
      add :lot_id, references(:hotel_credit_lots, on_delete: :delete_all)

      add :credit_allocation_id,
          references(:hotel_credit_allocations, on_delete: :delete_all)
    end

    create index(:room_allocations, [:group_id, :id])
    create index(:room_allocations, [:room_id, :id])
    create index(:room_allocations, [:operation_id, :id])
    create index(:room_allocations, [:credit_allocation_id])

    create table(:hotel_credit_entitlements) do
      add :lot_id,
          references(:hotel_credit_lots, on_delete: :delete_all),
          null: false

      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
    end

    create index(:hotel_credit_entitlements, [:lot_id])
    create index(:hotel_credit_entitlements, [:payment_operation_id])

    flush()

    backfill_rooms()
    backfill_cash_payments()
    backfill_room_allocations()
    backfill_entitlements()
  end

  def down do
    drop table(:hotel_credit_entitlements)
    drop table(:room_allocations)
    drop table(:cash_payments)

    alter table(:ledger_totals) do
      remove :cash_reduced_cents
      remove :cash_charged_back_cents
      remove :credit_shortfall_cents
    end

    alter table(:hotel_credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:rooms) do
      remove :status
      remove :lodging_total_cents
      remove :deposit_due_cents
      remove :cash_paid_cents
      remove :credit_paid_cents
    end
  end

  defp backfill_rooms do
    repo().query!("""
    UPDATE rooms
    SET status = COALESCE((
          SELECT groups.status
          FROM groups
          WHERE groups.group_id = rooms.group_id
        ), 'active'),
        lodging_total_cents = nightly_rate_cents * (
          SELECT CAST(julianday(groups.departure_on) - julianday(groups.arrival_on) AS INTEGER)
          FROM groups
          WHERE groups.group_id = rooms.group_id
        ),
        deposit_due_cents = CASE
          WHEN (SELECT groups.rate_plan FROM groups WHERE groups.group_id = rooms.group_id) = 'advance_purchase'
            THEN nightly_rate_cents * (
              SELECT CAST(julianday(groups.departure_on) - julianday(groups.arrival_on) AS INTEGER)
              FROM groups
              WHERE groups.group_id = rooms.group_id
            )
          ELSE (
            nightly_rate_cents * (
              SELECT CAST(julianday(groups.departure_on) - julianday(groups.arrival_on) AS INTEGER)
              FROM groups
              WHERE groups.group_id = rooms.group_id
            ) * 20 + 50
          ) / 100
        END
    """)
  end

  defp backfill_cash_payments do
    settlements = cancellation_settlements()

    rows!("""
    SELECT operations.operation_id,
           json_extract(operations.result_json, '$.group_id'),
           json_extract(operations.result_json, '$.amount_cents')
    FROM operations
    WHERE operations.type = 'record_cash_payment'
      AND json_extract(operations.result_json, '$.status') = 'applied'
    ORDER BY operations.id
    """)
    |> Enum.each(fn [operation_id, group_id, recorded_cents] ->
      {held_cents, refunded_cents, retained_cents, converted_cents} =
        case Map.get(settlements, group_id) do
          nil -> {recorded_cents, 0, 0, 0}
          :refunded -> {0, recorded_cents, 0, 0}
          :retained -> {0, 0, recorded_cents, 0}
          :converted -> {0, 0, 0, recorded_cents}
        end

      repo().query!(
        """
        INSERT INTO cash_payments
          (operation_id, group_id, recorded_cents, held_cents, refunded_cents,
           retained_cents, converted_to_credit_cents, reduced_cents, charged_back_cents)
        VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0)
        """,
        [
          operation_id,
          group_id,
          recorded_cents,
          held_cents,
          refunded_cents,
          retained_cents,
          converted_cents
        ]
      )
    end)
  end

  defp backfill_room_allocations do
    durable_funding = durable_funding()

    groups =
      rows!("""
      SELECT group_id,
             status,
             COALESCE(cash_paid_cents, deposit_paid_cents, 0),
             COALESCE(credit_paid_cents, 0)
      FROM groups
      ORDER BY group_id
      """)

    Enum.each(groups, fn [group_id, status, cash_paid_cents, credit_paid_cents] ->
      if status == "active" do
        rooms =
          rows!(
            """
            SELECT id, room_id, deposit_due_cents
            FROM rooms
            WHERE group_id = ? AND status = 'active'
            ORDER BY position, id
            """,
            [group_id]
          )
          |> Enum.map(fn [id, room_id, deposit_due_cents] ->
            %{
              id: id,
              room_id: room_id,
              deposit_due_cents: deposit_due_cents,
              cash_paid_cents: 0,
              credit_paid_cents: 0
            }
          end)

        group_funding = Map.get(durable_funding, group_id, [])

        durable_cash_cents =
          group_funding
          |> Enum.filter(&(&1.type == "cash"))
          |> Enum.reduce(0, &(&1.amount_cents + &2))

        durable_credit_cents =
          group_funding
          |> Enum.filter(&(&1.type == "credit"))
          |> Enum.reduce(0, &(&1.amount_cents + &2))

        legacy_cash_cents = max(cash_paid_cents - durable_cash_cents, 0)
        legacy_credit_cents = max(credit_paid_cents - durable_credit_cents, 0)

        credit_sources = credit_sources(group_id)

        {legacy_credit, remaining_credit_sources} =
          take_credit_sources(credit_sources, legacy_credit_cents)

        {funding, _remaining_credit_sources} =
          Enum.map_reduce(group_funding, remaining_credit_sources, fn source, sources ->
            if source.type == "cash" do
              {{source.type, source.operation_id, nil, nil, source.amount_cents}, sources}
            else
              {slices, sources} = take_credit_sources(sources, source.amount_cents)

              {Enum.map(slices, fn slice ->
                 {source.type, source.operation_id, slice.lot_id, slice.credit_allocation_id,
                  slice.amount_cents}
               end), sources}
            end
          end)

        funding =
          [{"cash", nil, nil, nil, legacy_cash_cents}] ++
            Enum.map(legacy_credit, fn slice ->
              {"credit", nil, slice.lot_id, slice.credit_allocation_id, slice.amount_cents}
            end) ++
            List.flatten(funding)

        allocate_funding(group_id, rooms, funding)
      end
    end)
  end

  defp backfill_entitlements do
    rows!("""
    SELECT operations.operation_id,
           json_extract(operations.result_json, '$.group_id'),
           json_extract(operations.result_json, '$.credit_issued_cents')
    FROM operations
    WHERE operations.type = 'cancel_group'
      AND json_extract(operations.result_json, '$.status') = 'applied'
      AND COALESCE(json_extract(operations.payload_json, '$.refund_method'), 'cash') = 'hotel_credit'
    ORDER BY operations.id
    """)
    |> Enum.each(fn [cancellation_operation_id, group_id, credit_issued_cents] ->
      if credit_issued_cents > 0 do
        lots =
          rows!(
            """
            SELECT id
            FROM hotel_credit_lots
            WHERE source_operation_id = ?
            ORDER BY id
            """,
            [cancellation_operation_id]
          )

        durable_payments =
          rows!(
            """
            SELECT cash_payments.operation_id, cash_payments.recorded_cents
            FROM cash_payments
            JOIN operations ON operations.operation_id = cash_payments.operation_id
            WHERE cash_payments.group_id = ?
            ORDER BY operations.id
            """,
            [group_id]
          )

        [[group_cash_paid_cents]] =
          rows!(
            """
            SELECT COALESCE(cash_paid_cents, deposit_paid_cents, 0)
            FROM groups
            WHERE group_id = ?
            """,
            [group_id]
          )

        durable_cash_cents =
          Enum.reduce(durable_payments, 0, fn [_operation_id, amount], total -> total + amount end)

        legacy_cash_cents = max(group_cash_paid_cents - durable_cash_cents, 0)

        contributions = entitlement_contributions(legacy_cash_cents, durable_payments)

        Enum.each(lots, fn [lot_id] ->
          Enum.each(contributions, fn {payment_operation_id, amount_cents} ->
            repo().query!(
              """
              INSERT INTO hotel_credit_entitlements (lot_id, payment_operation_id, amount_cents)
              VALUES (?, ?, ?)
              """,
              [lot_id, payment_operation_id, amount_cents]
            )
          end)
        end)
      end
    end)
  end

  defp cancellation_settlements do
    rows!("""
    SELECT json_extract(result_json, '$.group_id'),
           CASE
             WHEN COALESCE(json_extract(payload_json, '$.refund_method'), 'cash') = 'hotel_credit'
               THEN 'converted'
             WHEN json_extract(result_json, '$.refunded_cents') > 0
               THEN 'refunded'
             ELSE 'retained'
           END
    FROM operations
    WHERE type = 'cancel_group'
      AND json_extract(result_json, '$.status') = 'applied'
    ORDER BY id
    """)
    |> Map.new(fn [group_id, settlement] -> {group_id, String.to_atom(settlement)} end)
  end

  defp durable_funding do
    rows!("""
    SELECT operations.operation_id,
           json_extract(operations.result_json, '$.group_id'),
           CASE operations.type WHEN 'record_cash_payment' THEN 'cash' ELSE 'credit' END,
           json_extract(operations.result_json, '$.amount_cents')
    FROM operations
    WHERE operations.type IN ('record_cash_payment', 'apply_hotel_credit')
      AND json_extract(operations.result_json, '$.status') = 'applied'
    ORDER BY operations.id
    """)
    |> Enum.group_by(fn [_operation_id, group_id, _type, _amount_cents] -> group_id end)
    |> Map.new(fn {group_id, rows} ->
      sources =
        Enum.map(rows, fn [operation_id, _group_id, type, amount_cents] ->
          %{operation_id: operation_id, type: type, amount_cents: amount_cents}
        end)

      {group_id, sources}
    end)
  end

  defp credit_sources(group_id) do
    rows!(
      """
      SELECT id, lot_id, amount_cents
      FROM hotel_credit_allocations
      WHERE group_id = ?
      ORDER BY id
      """,
      [group_id]
    )
    |> Enum.map(fn [credit_allocation_id, lot_id, amount_cents] ->
      %{credit_allocation_id: credit_allocation_id, lot_id: lot_id, amount_cents: amount_cents}
    end)
  end

  defp take_credit_sources(sources, 0), do: {[], sources}

  defp take_credit_sources([], amount_cents) when amount_cents > 0 do
    raise "room accounting migration could not source #{amount_cents} cents of hotel credit"
  end

  defp take_credit_sources([source | rest], amount_cents) do
    allocated_cents = min(source.amount_cents, amount_cents)
    slice = %{source | amount_cents: allocated_cents}
    remaining_source_cents = source.amount_cents - allocated_cents

    remaining_sources =
      if remaining_source_cents > 0 do
        [%{source | amount_cents: remaining_source_cents} | rest]
      else
        rest
      end

    {slices, remaining_sources} =
      take_credit_sources(remaining_sources, amount_cents - allocated_cents)

    {[slice | slices], remaining_sources}
  end

  defp allocate_funding(group_id, rooms, funding) do
    Enum.reduce(funding, rooms, fn {funding_type, operation_id, lot_id, credit_allocation_id,
                                    amount},
                                   rooms ->
      allocate_funding_slice(
        group_id,
        rooms,
        funding_type,
        operation_id,
        lot_id,
        credit_allocation_id,
        amount
      )
    end)
    |> verify_room_totals!(group_id)
  end

  defp allocate_funding_slice(
         _group_id,
         rooms,
         _funding_type,
         _operation_id,
         _lot_id,
         _credit_allocation_id,
         0
       ),
       do: rooms

  defp allocate_funding_slice(
         group_id,
         rooms,
         funding_type,
         operation_id,
         lot_id,
         credit_allocation_id,
         amount_cents
       ) do
    {rooms, remaining_cents} =
      Enum.map_reduce(rooms, amount_cents, fn room, remaining_cents ->
        capacity_cents =
          max(room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents, 0)

        allocated_cents = min(capacity_cents, remaining_cents)

        if allocated_cents > 0 do
          repo().query!(
            """
            INSERT INTO room_allocations
              (group_id, room_id, funding_type, operation_id, amount_cents, lot_id, credit_allocation_id)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [
              group_id,
              room.room_id,
              funding_type,
              operation_id,
              allocated_cents,
              lot_id,
              credit_allocation_id
            ]
          )

          field = if funding_type == "cash", do: :cash_paid_cents, else: :credit_paid_cents

          repo().query!("UPDATE rooms SET #{field} = #{field} + ? WHERE id = ?", [
            allocated_cents,
            room.id
          ])
        end

        updated_room =
          case funding_type do
            "cash" -> %{room | cash_paid_cents: room.cash_paid_cents + allocated_cents}
            "credit" -> %{room | credit_paid_cents: room.credit_paid_cents + allocated_cents}
          end

        {updated_room, remaining_cents - allocated_cents}
      end)

    if remaining_cents > 0 do
      raise "room accounting migration overfunded group #{group_id} by #{remaining_cents} cents"
    end

    rooms
  end

  defp verify_room_totals!(rooms, group_id) do
    room_paid_cents =
      Enum.reduce(rooms, 0, fn room, total ->
        total + room.cash_paid_cents + room.credit_paid_cents
      end)

    [[group_paid_cents]] =
      rows!(
        """
        SELECT COALESCE(cash_paid_cents, deposit_paid_cents, 0) + COALESCE(credit_paid_cents, 0)
        FROM groups
        WHERE group_id = ?
        """,
        [group_id]
      )

    if room_paid_cents != group_paid_cents do
      raise "room accounting migration left group #{group_id} with #{group_paid_cents - room_paid_cents} unallocated cents"
    end

    rooms
  end

  defp entitlement_contributions(legacy_cash_cents, durable_payments) do
    {contributions, _running_cash_cents} =
      Enum.reduce(durable_payments, {[], legacy_cash_cents}, fn [operation_id, payment_cents],
                                                                {contributions,
                                                                 running_cash_cents} ->
        next_running_cash_cents = running_cash_cents + payment_cents

        contribution_cents =
          credit_amount(next_running_cash_cents) - credit_amount(running_cash_cents)

        {[{operation_id, contribution_cents} | contributions], next_running_cash_cents}
      end)

    contributions = Enum.reverse(contributions)

    legacy_entitlement =
      if legacy_cash_cents > 0, do: [{nil, credit_amount(legacy_cash_cents)}], else: []

    legacy_entitlement ++ contributions
  end

  defp credit_amount(cash_cents), do: cash_cents + div(cash_cents * 10 + 50, 100)

  defp rows!(sql, params \\ []) do
    %{rows: rows} = repo().query!(sql, params)
    rows
  end
end
