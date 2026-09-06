defmodule GroupStay.Repo.Migrations.AddRoomFundingLedger do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    create table(:cash_sources) do
      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :delete_all),
          null: false

      add :payment_operation_id, :string
      add :funding_order, :integer
      add :recorded_cents, :integer, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
    end

    create index(:cash_sources, [:group_id, :funding_order])
    create unique_index(:cash_sources, [:payment_operation_id])

    create table(:cash_allocations) do
      add :cash_source_id, references(:cash_sources, on_delete: :restrict), null: false
      add :room_id, references(:rooms, on_delete: :restrict), null: false
      add :amount_cents, :integer, null: false
    end

    create index(:cash_allocations, [:cash_source_id])
    create index(:cash_allocations, [:room_id])

    alter table(:credit_allocations) do
      add :room_id, references(:rooms, on_delete: :restrict)
      add :funding_operation_id, :string
    end

    create index(:credit_allocations, [:room_id])
    create index(:credit_allocations, [:funding_operation_id])

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots, on_delete: :restrict), null: false
      add :cash_source_id, references(:cash_sources, on_delete: :restrict), null: false
      add :principal_cents, :integer, null: false
      add :entitlement_cents, :integer, null: false
      add :revoked_cents, :integer, null: false, default: 0
    end

    create unique_index(:credit_entitlements, [:credit_lot_id, :cash_source_id])
    create index(:credit_entitlements, [:cash_source_id])

    flush()
    backfill()
  end

  def down do
    drop table(:credit_entitlements)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    drop index(:credit_allocations, [:funding_operation_id])
    drop index(:credit_allocations, [:room_id])

    alter table(:credit_allocations) do
      remove :funding_operation_id
      remove :room_id
    end

    drop table(:cash_allocations)
    drop table(:cash_sources)

    alter table(:rooms) do
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :deposit_due_cents
      remove :lodging_total_cents
      remove :status
    end
  end

  defp backfill do
    operations = load_operations()

    query!("""
    SELECT group_id, status, arrival_on, departure_on, rate_plan, cash_paid_cents,
           credit_paid_cents, refunded_cents, retained_cents,
           cash_converted_to_credit_cents
    FROM groups
    ORDER BY group_id
    """)
    |> rows_as([
      :group_id,
      :status,
      :arrival_on,
      :departure_on,
      :rate_plan,
      :cash_paid_cents,
      :credit_paid_cents,
      :refunded_cents,
      :retained_cents,
      :converted_cents
    ])
    |> Enum.each(&backfill_group(&1, operations))
  end

  defp load_operations do
    query!("""
    SELECT id, operation_id, operation_type, submission, result
    FROM partner_operations
    WHERE operation_type IN ('record_cash_payment', 'apply_hotel_credit', 'cancel_group')
    ORDER BY id
    """)
    |> rows_as([:id, :operation_id, :type, :submission, :result])
    |> Enum.map(fn operation ->
      %{
        operation
        | submission: decode_map(operation.submission),
          result: decode_map(operation.result)
      }
    end)
    |> Enum.filter(&(&1.result["status"] == "applied"))
    |> Enum.map(&Map.put(&1, :group_id, &1.result["group_id"] || &1.submission["group_id"]))
  end

  defp backfill_group(group, operations) do
    group_operations = Enum.filter(operations, &(&1.group_id == group.group_id))
    rooms = backfill_rooms(group)
    sources = create_cash_sources(group, group_operations)

    case group.status do
      "active" -> backfill_active_group(group, rooms, sources, group_operations)
      "cancelled" -> backfill_cancelled_group(group, sources, group_operations)
    end
  end

  defp backfill_rooms(group) do
    nights =
      Date.diff(Date.from_iso8601!(group.departure_on), Date.from_iso8601!(group.arrival_on))

    query!(
      "SELECT id, nightly_rate_cents FROM rooms WHERE group_id = ? ORDER BY position, id",
      [group.group_id]
    )
    |> rows_as([:id, :nightly_rate_cents])
    |> Enum.map(fn room ->
      lodging = room.nightly_rate_cents * nights

      deposit =
        if group.rate_plan == "advance_purchase", do: lodging, else: round_ratio(lodging, 20)

      query!(
        """
        UPDATE rooms
        SET status = ?, lodging_total_cents = ?, deposit_due_cents = ?,
            cash_paid_cents = 0, credit_paid_cents = 0
        WHERE id = ?
        """,
        [group.status, lodging, deposit, room.id]
      )

      %{id: room.id, remaining_cents: deposit, cash_paid_cents: 0, credit_paid_cents: 0}
    end)
  end

  defp create_cash_sources(group, operations) do
    cash_operations = Enum.filter(operations, &(&1.type == "record_cash_payment"))
    durable_total = Enum.sum(Enum.map(cash_operations, &operation_amount!/1))
    legacy_amount = group.cash_paid_cents - durable_total

    if legacy_amount < 0 do
      raise "durable cash exceeds aggregate cash for group #{inspect(group.group_id)}"
    end

    legacy_sources =
      if legacy_amount > 0 do
        [insert_cash_source(group.group_id, nil, 0, legacy_amount)]
      else
        []
      end

    durable_sources =
      Enum.map(cash_operations, fn operation ->
        insert_cash_source(
          group.group_id,
          operation.operation_id,
          operation.id,
          operation_amount!(operation)
        )
      end)

    legacy_sources ++ durable_sources
  end

  defp insert_cash_source(group_id, operation_id, funding_order, amount) do
    result =
      query!(
        """
        INSERT INTO cash_sources
          (group_id, payment_operation_id, funding_order, recorded_cents)
        VALUES (?, ?, ?, ?)
        RETURNING id
        """,
        [group_id, operation_id, funding_order, amount]
      )

    %{id: result.rows |> hd() |> hd(), operation_id: operation_id, amount_cents: amount}
  end

  defp backfill_cancelled_group(group, sources, operations) do
    disposition = cancellation_disposition!(group)

    Enum.each(sources, fn source ->
      query!(
        "UPDATE cash_sources SET #{disposition} = ? WHERE id = ?",
        [source.amount_cents, source.id]
      )
    end)

    durable_sources = Enum.reject(sources, &is_nil(&1.operation_id))

    if disposition == "converted_to_credit_cents" and durable_sources != [] do
      cancellation =
        Enum.find(operations, fn operation -> operation.type == "cancel_group" end) ||
          raise "missing applied cancellation for converted group #{inspect(group.group_id)}"

      lot_result =
        query!("SELECT id FROM credit_lots WHERE source_operation_id = ? ORDER BY id", [
          cancellation.operation_id
        ])

      lot_id =
        case lot_result.rows do
          [[id]] -> id
          _ -> raise "expected one cancellation credit lot for group #{inspect(group.group_id)}"
        end

      insert_entitlements(sources, lot_id)
    end

    query!(
      """
      UPDATE groups
      SET lodging_total_cents = 0, deposit_due_cents = 0, deposit_paid_cents = 0,
          cash_paid_cents = 0, credit_paid_cents = 0
      WHERE group_id = ?
      """,
      [group.group_id]
    )
  end

  defp cancellation_disposition!(group) do
    dispositions = [
      {"refunded_cents", group.refunded_cents},
      {"retained_cents", group.retained_cents},
      {"converted_to_credit_cents", group.converted_cents}
    ]

    case Enum.filter(dispositions, fn {_field, amount} -> amount > 0 end) do
      [] when group.cash_paid_cents == 0 -> "refunded_cents"
      [{field, amount}] when amount == group.cash_paid_cents -> field
      _ -> raise "invalid legacy cancellation totals for group #{inspect(group.group_id)}"
    end
  end

  defp insert_entitlements(sources, lot_id) do
    Enum.reduce(sources, {0, 0}, fn source, {principal_so_far, entitlement_so_far} ->
      next_principal = principal_so_far + source.amount_cents
      next_entitlement = round_ratio(next_principal, 110)
      entitlement = next_entitlement - entitlement_so_far

      query!(
        """
        INSERT INTO credit_entitlements
          (credit_lot_id, cash_source_id, principal_cents, entitlement_cents)
        VALUES (?, ?, ?, ?)
        """,
        [lot_id, source.id, source.amount_cents, entitlement]
      )

      {next_principal, next_entitlement}
    end)
  end

  defp backfill_active_group(group, rooms, sources, operations) do
    allocations = load_credit_allocations(group.group_id)

    durable_credit =
      operations
      |> Enum.filter(&(&1.type == "apply_hotel_credit"))
      |> Enum.map(&operation_amount!/1)
      |> Enum.sum()

    legacy_credit = group.credit_paid_cents - durable_credit

    if legacy_credit < 0 do
      raise "durable credit exceeds aggregate credit for group #{inspect(group.group_id)}"
    end

    legacy_source = Enum.find(sources, &is_nil(&1.operation_id))

    rooms =
      if legacy_source do
        allocate_cash(rooms, legacy_source.id, legacy_source.amount_cents)
      else
        rooms
      end

    {rooms, credit_stream, credit_rows} =
      consume_credit(allocations, legacy_credit, nil, rooms, [])

    {rooms, credit_stream, credit_rows} =
      Enum.reduce(operations, {rooms, credit_stream, credit_rows}, fn
        %{type: "record_cash_payment", operation_id: operation_id} = operation,
        {current_rooms, stream, rows} ->
          source = Enum.find(sources, &(&1.operation_id == operation_id))
          {allocate_cash(current_rooms, source.id, operation_amount!(operation)), stream, rows}

        %{type: "apply_hotel_credit"} = operation, {current_rooms, stream, rows} ->
          consume_credit(
            stream,
            operation_amount!(operation),
            operation.operation_id,
            current_rooms,
            rows
          )

        _operation, state ->
          state
      end)

    if Enum.any?(credit_stream, &(&1.amount_cents > 0)) do
      raise "unattributed credit allocations for group #{inspect(group.group_id)}"
    end

    paid = Enum.sum(Enum.map(rooms, &(&1.cash_paid_cents + &1.credit_paid_cents)))

    if paid != group.cash_paid_cents + group.credit_paid_cents do
      raise "room funding does not match aggregate funding for group #{inspect(group.group_id)}"
    end

    replace_credit_allocations(group.group_id, credit_rows)
    update_room_payments(rooms)
  end

  defp load_credit_allocations(group_id) do
    query!(
      """
      SELECT credit_lot_id, amount_cents
      FROM credit_allocations
      WHERE group_id = ?
      ORDER BY id
      """,
      [group_id]
    )
    |> rows_as([:credit_lot_id, :amount_cents])
  end

  defp allocate_cash(rooms, source_id, amount) do
    {rooms, room_amounts} = allocate_to_rooms(rooms, amount, :cash_paid_cents)

    Enum.each(room_amounts, fn {room_id, room_amount} ->
      query!(
        """
        INSERT INTO cash_allocations (cash_source_id, room_id, amount_cents)
        VALUES (?, ?, ?)
        """,
        [source_id, room_id, room_amount]
      )
    end)

    rooms
  end

  defp consume_credit(stream, 0, _operation_id, rooms, rows),
    do: {rooms, stream, rows}

  defp consume_credit([], amount, operation_id, _rooms, _rows) do
    raise "missing #{amount} cents of credit allocations for #{inspect(operation_id || :legacy)}"
  end

  defp consume_credit([allocation | rest], amount, operation_id, rooms, rows) do
    consumed = min(allocation.amount_cents, amount)
    {rooms, room_amounts} = allocate_to_rooms(rooms, consumed, :credit_paid_cents)

    new_rows =
      Enum.map(room_amounts, fn {room_id, room_amount} ->
        %{
          credit_lot_id: allocation.credit_lot_id,
          room_id: room_id,
          funding_operation_id: operation_id,
          amount_cents: room_amount
        }
      end)

    remaining_allocation = allocation.amount_cents - consumed

    next_stream =
      if remaining_allocation == 0,
        do: rest,
        else: [%{allocation | amount_cents: remaining_allocation} | rest]

    consume_credit(next_stream, amount - consumed, operation_id, rooms, rows ++ new_rows)
  end

  defp allocate_to_rooms(rooms, amount, field) do
    {rooms, remaining, allocations} =
      Enum.reduce(rooms, {[], amount, []}, fn room, {updated, needed, allocated} ->
        room_amount = min(room.remaining_cents, needed)

        updated_room =
          room
          |> Map.update!(:remaining_cents, &(&1 - room_amount))
          |> Map.update!(field, &(&1 + room_amount))

        allocated =
          if room_amount > 0, do: [{room.id, room_amount} | allocated], else: allocated

        {updated ++ [updated_room], needed - room_amount, allocated}
      end)

    if remaining > 0, do: raise("funding exceeds active room deposits by #{remaining} cents")
    {rooms, Enum.reverse(allocations)}
  end

  defp replace_credit_allocations(group_id, rows) do
    query!("DELETE FROM credit_allocations WHERE group_id = ?", [group_id])

    Enum.each(rows, fn row ->
      query!(
        """
        INSERT INTO credit_allocations
          (credit_lot_id, group_id, room_id, funding_operation_id, amount_cents)
        VALUES (?, ?, ?, ?, ?)
        """,
        [
          row.credit_lot_id,
          group_id,
          row.room_id,
          row.funding_operation_id,
          row.amount_cents
        ]
      )
    end)
  end

  defp update_room_payments(rooms) do
    Enum.each(rooms, fn room ->
      query!("UPDATE rooms SET cash_paid_cents = ?, credit_paid_cents = ? WHERE id = ?", [
        room.cash_paid_cents,
        room.credit_paid_cents,
        room.id
      ])
    end)
  end

  defp operation_amount!(operation) do
    case operation.result["amount_cents"] do
      amount when is_integer(amount) and amount > 0 -> amount
      _ -> raise "invalid amount in applied operation #{inspect(operation.operation_id)}"
    end
  end

  defp round_ratio(amount, percentage), do: div(amount * percentage + 50, 100)

  defp rows_as(result, keys), do: Enum.map(result.rows, &Map.new(Enum.zip(keys, &1)))

  defp decode_map(value) when is_map(value), do: value
  defp decode_map(value) when is_binary(value), do: Jason.decode!(value)

  defp query!(sql, params \\ []), do: repo().query!(sql, params)
end
