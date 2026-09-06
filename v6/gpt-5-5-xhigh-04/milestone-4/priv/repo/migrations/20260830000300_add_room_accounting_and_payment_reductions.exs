defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions do
  use Ecto.Migration

  @active "active"
  @held "held"
  @refunded "refunded"
  @retained "retained"
  @converted_to_credit "converted_to_credit"

  def up do
    alter table(:group_rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
    end

    execute("""
    UPDATE group_rooms
    SET
      status = (
        SELECT CASE WHEN groups.status = 'cancelled' THEN 'cancelled' ELSE 'active' END
        FROM groups
        WHERE groups.id = group_rooms.reservation_id
      ),
      lodging_total_cents = nightly_rate_cents * (
        SELECT CAST(julianday(groups.departure_on) - julianday(groups.arrival_on) AS INTEGER)
        FROM groups
        WHERE groups.id = group_rooms.reservation_id
      )
    """)

    execute("""
    UPDATE group_rooms
    SET deposit_due_cents = CASE (
        SELECT groups.rate_plan
        FROM groups
        WHERE groups.id = group_rooms.reservation_id
      )
      WHEN 'advance_purchase' THEN lodging_total_cents
      ELSE CAST(((lodging_total_cents * 20) + 50) / 100 AS INTEGER)
    END
    """)

    alter table(:hotel_credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:cash_payment_dispositions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :reservation_id, references(:groups, type: :binary_id, on_delete: :delete_all),
        null: false

      add :room_id, references(:group_rooms, type: :binary_id, on_delete: :delete_all),
        null: false

      add :credit_lot_id, references(:hotel_credit_lots, type: :binary_id, on_delete: :nilify_all)
      add :payment_operation_id, :string
      add :disposition, :string, null: false
      add :amount_cents, :integer, null: false
      add :sequence, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:cash_payment_dispositions, [:payment_operation_id])
    create index(:cash_payment_dispositions, [:reservation_id, :disposition])
    create index(:cash_payment_dispositions, [:room_id, :disposition])
    create index(:cash_payment_dispositions, [:credit_lot_id])
    create index(:cash_payment_dispositions, [:sequence])

    create table(:room_credit_allocations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :reservation_id, references(:groups, type: :binary_id, on_delete: :delete_all),
        null: false

      add :room_id, references(:group_rooms, type: :binary_id, on_delete: :delete_all),
        null: false

      add :credit_lot_id, references(:hotel_credit_lots, type: :binary_id, on_delete: :restrict),
        null: false

      add :source_operation_id, :string
      add :amount_cents, :integer, null: false
      add :active, :boolean, null: false, default: true
      add :sequence, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:room_credit_allocations, [:reservation_id, :active])
    create index(:room_credit_allocations, [:room_id, :active])
    create index(:room_credit_allocations, [:credit_lot_id, :active])
    create index(:room_credit_allocations, [:source_operation_id])
    create index(:room_credit_allocations, [:sequence])

    create table(:credit_lot_cash_sources, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :credit_lot_id,
          references(:hotel_credit_lots, type: :binary_id, on_delete: :delete_all), null: false

      add :payment_operation_id, :string
      add :cash_cents, :integer, null: false
      add :credit_cents, :integer, null: false
      add :source_order, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:credit_lot_cash_sources, [:credit_lot_id])
    create index(:credit_lot_cash_sources, [:payment_operation_id])
    create index(:credit_lot_cash_sources, [:source_order])

    flush()
    backfill_existing_accounting()
  end

  def down do
    drop index(:credit_lot_cash_sources, [:source_order])
    drop index(:credit_lot_cash_sources, [:payment_operation_id])
    drop index(:credit_lot_cash_sources, [:credit_lot_id])
    drop table(:credit_lot_cash_sources)

    drop index(:room_credit_allocations, [:sequence])
    drop index(:room_credit_allocations, [:source_operation_id])
    drop index(:room_credit_allocations, [:credit_lot_id, :active])
    drop index(:room_credit_allocations, [:room_id, :active])
    drop index(:room_credit_allocations, [:reservation_id, :active])
    drop table(:room_credit_allocations)

    drop index(:cash_payment_dispositions, [:sequence])
    drop index(:cash_payment_dispositions, [:credit_lot_id])
    drop index(:cash_payment_dispositions, [:room_id, :disposition])
    drop index(:cash_payment_dispositions, [:reservation_id, :disposition])
    drop index(:cash_payment_dispositions, [:payment_operation_id])
    drop table(:cash_payment_dispositions)

    alter table(:hotel_credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:group_rooms) do
      remove :deposit_due_cents
      remove :lodging_total_cents
      remove :status
    end
  end

  defp backfill_existing_accounting do
    Enum.reduce(groups(), 1, fn group, next_sequence ->
      rooms = rooms_for_group(group.id)
      cash_sources = cash_sources_for_group(group.group_id, recorded_cash_cents(group))

      {rooms, _cash_sources, next_sequence, converted_rows} =
        group
        |> cash_disposition_buckets()
        |> Enum.reduce({rooms, cash_sources, next_sequence, []}, fn {disposition, cents},
                                                                    {rooms, sources, sequence,
                                                                     converted_rows} ->
          {rooms, sources, sequence, new_rows} =
            allocate_cash_bucket(group.id, rooms, sources, disposition, cents, sequence)

          {rooms, sources, sequence, converted_rows ++ new_rows}
        end)

      create_backfilled_credit_lot_sources(group, converted_rows)

      {_rooms, next_sequence} =
        allocate_active_credit_applications(group.id, rooms, next_sequence)

      next_sequence
    end)
  end

  defp groups do
    query!("""
    SELECT id, group_id, status, cash_paid_cents, cash_refunded_cents, cash_retained_cents,
      cash_converted_to_credit_cents
    FROM groups
    ORDER BY inserted_at, id
    """).rows
    |> Enum.map(fn [
                     id,
                     group_id,
                     status,
                     cash_paid_cents,
                     cash_refunded_cents,
                     cash_retained_cents,
                     cash_converted_to_credit_cents
                   ] ->
      %{
        id: id,
        group_id: group_id,
        status: status,
        cash_paid_cents: cents(cash_paid_cents),
        cash_refunded_cents: cents(cash_refunded_cents),
        cash_retained_cents: cents(cash_retained_cents),
        cash_converted_to_credit_cents: cents(cash_converted_to_credit_cents)
      }
    end)
  end

  defp rooms_for_group(group_id) do
    query!(
      """
      SELECT id, deposit_due_cents
      FROM group_rooms
      WHERE reservation_id = ?
      ORDER BY position, id
      """,
      [group_id]
    ).rows
    |> Enum.map(fn [id, deposit_due_cents] ->
      %{id: id, remaining_deposit_cents: cents(deposit_due_cents)}
    end)
  end

  defp cash_disposition_buckets(%{status: @active, cash_paid_cents: cash_paid_cents}) do
    [{@held, cash_paid_cents}]
  end

  defp cash_disposition_buckets(group) do
    [
      {@refunded, group.cash_refunded_cents},
      {@retained, group.cash_retained_cents},
      {@converted_to_credit, group.cash_converted_to_credit_cents}
    ]
  end

  defp recorded_cash_cents(%{status: @active, cash_paid_cents: cash_paid_cents}) do
    cash_paid_cents
  end

  defp recorded_cash_cents(group) do
    settled_cents =
      group.cash_refunded_cents + group.cash_retained_cents + group.cash_converted_to_credit_cents

    max(group.cash_paid_cents, settled_cents)
  end

  defp cash_sources_for_group(_group_id, 0), do: []

  defp cash_sources_for_group(group_id, recorded_cash_cents) do
    durable_sources =
      query!("""
      SELECT operation_id, result
      FROM partner_operations
      WHERE operation_type = 'record_cash_payment'
      ORDER BY id
      """).rows
      |> Enum.flat_map(fn [operation_id, result] ->
        result = decode_json(result)

        if result["status"] == "applied" and result["group_id"] == group_id do
          [%{payment_operation_id: operation_id, remaining_cents: cents(result["amount_cents"])}]
        else
          []
        end
      end)

    durable_cents = Enum.sum(Enum.map(durable_sources, & &1.remaining_cents))
    legacy_cents = max(recorded_cash_cents - durable_cents, 0)

    maybe_legacy_source =
      if legacy_cents > 0 do
        [%{payment_operation_id: nil, remaining_cents: legacy_cents}]
      else
        []
      end

    (maybe_legacy_source ++ durable_sources)
    |> cap_sources(recorded_cash_cents)
  end

  defp cap_sources(sources, capped_cents) do
    {_remaining_cents, capped_sources} =
      Enum.reduce_while(sources, {capped_cents, []}, fn source,
                                                        {remaining_cents, capped_sources} ->
        cond do
          remaining_cents == 0 ->
            {:halt, {0, capped_sources}}

          source.remaining_cents <= remaining_cents ->
            {:cont, {remaining_cents - source.remaining_cents, capped_sources ++ [source]}}

          true ->
            capped_source = %{source | remaining_cents: remaining_cents}
            {:halt, {0, capped_sources ++ [capped_source]}}
        end
      end)

    capped_sources
  end

  defp allocate_cash_bucket(_group_id, rooms, sources, _disposition, 0, sequence) do
    {rooms, sources, sequence, []}
  end

  defp allocate_cash_bucket(group_id, rooms, sources, disposition, cents, sequence) do
    {rooms, sources, _remaining_cents, sequence, inserted_rows} =
      allocate_cash_rows(group_id, rooms, sources, disposition, cents, sequence, [])

    {rooms, sources, sequence, inserted_rows}
  end

  defp allocate_cash_rows(group_id, rooms, sources, disposition, remaining_cents, sequence, rows)

  defp allocate_cash_rows(_group_id, rooms, sources, _disposition, 0, sequence, rows) do
    {rooms, sources, 0, sequence, rows}
  end

  defp allocate_cash_rows(_group_id, rooms, [], _disposition, remaining_cents, sequence, rows) do
    {rooms, [], remaining_cents, sequence, rows}
  end

  defp allocate_cash_rows(_group_id, [], sources, _disposition, remaining_cents, sequence, rows) do
    {[], sources, remaining_cents, sequence, rows}
  end

  defp allocate_cash_rows(
         group_id,
         [%{remaining_deposit_cents: 0} = room | rooms],
         sources,
         disposition,
         remaining_cents,
         sequence,
         rows
       ) do
    {rooms, sources, remaining_cents, sequence, rows} =
      allocate_cash_rows(group_id, rooms, sources, disposition, remaining_cents, sequence, rows)

    {[room | rooms], sources, remaining_cents, sequence, rows}
  end

  defp allocate_cash_rows(
         group_id,
         rooms,
         [%{remaining_cents: 0} | sources],
         disposition,
         remaining_cents,
         sequence,
         rows
       ) do
    allocate_cash_rows(group_id, rooms, sources, disposition, remaining_cents, sequence, rows)
  end

  defp allocate_cash_rows(
         group_id,
         [room | rooms],
         [source | sources],
         disposition,
         remaining_cents,
         sequence,
         rows
       ) do
    amount_cents = min(room.remaining_deposit_cents, min(source.remaining_cents, remaining_cents))

    row = %{
      id: Ecto.UUID.generate(),
      reservation_id: group_id,
      room_id: room.id,
      payment_operation_id: source.payment_operation_id,
      disposition: disposition,
      amount_cents: amount_cents,
      sequence: sequence
    }

    insert_cash_disposition(row)

    next_room = %{room | remaining_deposit_cents: room.remaining_deposit_cents - amount_cents}
    next_source = %{source | remaining_cents: source.remaining_cents - amount_cents}

    allocate_cash_rows(
      group_id,
      [next_room | rooms],
      [next_source | sources],
      disposition,
      remaining_cents - amount_cents,
      sequence + 1,
      rows ++ [row]
    )
  end

  defp create_backfilled_credit_lot_sources(_group, []), do: :ok

  defp create_backfilled_credit_lot_sources(group, converted_rows) do
    case converted_credit_lot(group) do
      nil ->
        :ok

      credit_lot_id ->
        Enum.each(converted_rows, &set_cash_disposition_credit_lot(&1.id, credit_lot_id))

        converted_rows
        |> credit_lot_source_principals()
        |> Enum.reduce({0, 1}, fn source, {previous_cash_cents, source_order} ->
          running_cash_cents = previous_cash_cents + source.cash_cents

          credit_cents =
            credit_issued_cents(running_cash_cents) - credit_issued_cents(previous_cash_cents)

          insert_credit_lot_cash_source(%{
            credit_lot_id: credit_lot_id,
            payment_operation_id: source.payment_operation_id,
            cash_cents: source.cash_cents,
            credit_cents: credit_cents,
            source_order: source_order
          })

          {running_cash_cents, source_order + 1}
        end)

        :ok
    end
  end

  defp converted_credit_lot(group) do
    cancel_operation_ids =
      query!("""
      SELECT operation_id, result
      FROM partner_operations
      WHERE operation_type = 'cancel_group'
      ORDER BY id
      """).rows
      |> Enum.flat_map(fn [operation_id, result] ->
        result = decode_json(result)

        if result["status"] == "applied" and result["group_id"] == group.group_id and
             cents(result["credit_issued_cents"]) > 0 do
          [operation_id]
        else
          []
        end
      end)

    case cancel_operation_ids do
      [] ->
        nil

      [operation_id | _rest] ->
        query!(
          """
          SELECT id
          FROM hotel_credit_lots
          WHERE source_operation_id = ?
          ORDER BY inserted_at, id
          LIMIT 1
          """,
          [operation_id]
        ).rows
        |> case do
          [[credit_lot_id]] -> credit_lot_id
          _other -> nil
        end
    end
  end

  defp credit_lot_source_principals(cash_rows) do
    Enum.reduce(cash_rows, [], fn row, sources ->
      case List.last(sources) do
        %{payment_operation_id: payment_operation_id, cash_cents: cash_cents}
        when payment_operation_id == row.payment_operation_id ->
          List.replace_at(sources, -1, %{
            payment_operation_id: payment_operation_id,
            cash_cents: cash_cents + row.amount_cents
          })

        _other ->
          sources ++
            [%{payment_operation_id: row.payment_operation_id, cash_cents: row.amount_cents}]
      end
    end)
  end

  defp allocate_active_credit_applications(group_id, rooms, sequence) do
    query!(
      """
      SELECT credit_lot_id, amount_cents
      FROM group_credit_applications
      WHERE reservation_id = ? AND active = 1
      ORDER BY inserted_at, id
      """,
      [group_id]
    ).rows
    |> Enum.reduce({rooms, sequence}, fn [credit_lot_id, amount_cents], {rooms, sequence} ->
      allocate_credit_rows(group_id, rooms, credit_lot_id, cents(amount_cents), sequence)
    end)
  end

  defp allocate_credit_rows(group_id, rooms, credit_lot_id, amount_cents, sequence) do
    {rooms, _remaining_cents, sequence} =
      allocate_credit_rows(group_id, rooms, credit_lot_id, amount_cents, sequence, [])

    {rooms, sequence}
  end

  defp allocate_credit_rows(_group_id, rooms, _credit_lot_id, 0, sequence, rebuilt_rooms) do
    {Enum.reverse(rebuilt_rooms) ++ rooms, 0, sequence}
  end

  defp allocate_credit_rows(_group_id, [], _credit_lot_id, amount_cents, sequence, rebuilt_rooms) do
    {Enum.reverse(rebuilt_rooms), amount_cents, sequence}
  end

  defp allocate_credit_rows(
         group_id,
         [%{remaining_deposit_cents: 0} = room | rooms],
         credit_lot_id,
         amount_cents,
         sequence,
         rebuilt_rooms
       ) do
    allocate_credit_rows(group_id, rooms, credit_lot_id, amount_cents, sequence, [
      room | rebuilt_rooms
    ])
  end

  defp allocate_credit_rows(
         group_id,
         [room | rooms],
         credit_lot_id,
         amount_cents,
         sequence,
         rebuilt_rooms
       ) do
    allocated_cents = min(room.remaining_deposit_cents, amount_cents)

    insert_room_credit_allocation(%{
      reservation_id: group_id,
      room_id: room.id,
      credit_lot_id: credit_lot_id,
      amount_cents: allocated_cents,
      sequence: sequence
    })

    next_room = %{room | remaining_deposit_cents: room.remaining_deposit_cents - allocated_cents}

    allocate_credit_rows(
      group_id,
      [next_room | rooms],
      credit_lot_id,
      amount_cents - allocated_cents,
      sequence + 1,
      rebuilt_rooms
    )
  end

  defp insert_cash_disposition(attrs) do
    query!(
      """
      INSERT INTO cash_payment_dispositions
        (id, reservation_id, room_id, payment_operation_id, disposition, amount_cents, sequence,
          inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        attrs.id,
        attrs.reservation_id,
        attrs.room_id,
        attrs.payment_operation_id,
        attrs.disposition,
        attrs.amount_cents,
        attrs.sequence,
        timestamp(),
        timestamp()
      ]
    )
  end

  defp set_cash_disposition_credit_lot(cash_disposition_id, credit_lot_id) do
    query!(
      """
      UPDATE cash_payment_dispositions
      SET credit_lot_id = ?
      WHERE id = ?
      """,
      [credit_lot_id, cash_disposition_id]
    )
  end

  defp insert_credit_lot_cash_source(attrs) do
    query!(
      """
      INSERT INTO credit_lot_cash_sources
        (id, credit_lot_id, payment_operation_id, cash_cents, credit_cents, source_order,
          inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        Ecto.UUID.generate(),
        attrs.credit_lot_id,
        attrs.payment_operation_id,
        attrs.cash_cents,
        attrs.credit_cents,
        attrs.source_order,
        timestamp(),
        timestamp()
      ]
    )
  end

  defp insert_room_credit_allocation(attrs) do
    query!(
      """
      INSERT INTO room_credit_allocations
        (id, reservation_id, room_id, credit_lot_id, amount_cents, active, sequence,
          inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?)
      """,
      [
        Ecto.UUID.generate(),
        attrs.reservation_id,
        attrs.room_id,
        attrs.credit_lot_id,
        attrs.amount_cents,
        attrs.sequence,
        timestamp(),
        timestamp()
      ]
    )
  end

  defp query!(sql, params \\ []) do
    repo().query!(sql, params)
  end

  defp decode_json(nil), do: %{}
  defp decode_json(%{} = value), do: value

  defp decode_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{} = decoded} -> decoded
      _other -> %{}
    end
  end

  defp credit_issued_cents(cash_cents) do
    cash_cents + div(cash_cents * 10 + 50, 100)
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:microsecond)
    |> DateTime.to_iso8601()
  end

  defp cents(nil), do: 0
  defp cents(value), do: value
end
