defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentDispositions do
  use Ecto.Migration

  def up do
    alter table(:group_rooms) do
      add :status, :string, null: false, default: "active"
    end

    alter table(:hotel_credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:room_cash_allocations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_pk_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false

      add :group_room_id, references(:group_rooms, type: :binary_id, on_delete: :delete_all),
        null: false

      add :source_operation_id, :string
      add :amount_cents, :integer, null: false
      add :funding_order, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:room_cash_allocations, [:group_pk_id])
    create index(:room_cash_allocations, [:group_room_id])
    create index(:room_cash_allocations, [:source_operation_id])

    create table(:room_credit_allocations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_pk_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false

      add :group_room_id, references(:group_rooms, type: :binary_id, on_delete: :delete_all),
        null: false

      add :hotel_credit_lot_id,
          references(:hotel_credit_lots, type: :binary_id, on_delete: :restrict),
          null: false

      add :application_operation_id, :string
      add :amount_cents, :integer, null: false
      add :funding_order, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:room_credit_allocations, [:group_pk_id])
    create index(:room_credit_allocations, [:group_room_id])
    create index(:room_credit_allocations, [:hotel_credit_lot_id])

    create table(:payment_cash_dispositions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_pk_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :payment_operation_id, :string, null: false
      add :recorded_cents, :integer, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
      add :charged_back, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:payment_cash_dispositions, [:payment_operation_id])
    create index(:payment_cash_dispositions, [:group_pk_id])

    create table(:credit_lot_entitlements, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :hotel_credit_lot_id,
          references(:hotel_credit_lots, type: :binary_id, on_delete: :delete_all),
          null: false

      add :payment_operation_id, :string
      add :principal_cents, :integer, null: false
      add :entitlement_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_lot_entitlements, [:hotel_credit_lot_id])
    create index(:credit_lot_entitlements, [:payment_operation_id])

    flush()

    backfill_room_accounting()
  end

  def down do
    drop table(:credit_lot_entitlements)
    drop table(:payment_cash_dispositions)
    drop table(:room_credit_allocations)
    drop table(:room_cash_allocations)

    alter table(:hotel_credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:group_rooms) do
      remove :status
    end
  end

  defp backfill_room_accounting do
    groups = load_groups()
    rooms_by_group = load_rooms_by_group()
    payments_by_group = load_applied_payments_by_group(groups)

    Enum.each(groups, fn group ->
      payments = Map.get(payments_by_group, group.id, [])

      backfill_payment_dispositions(group, payments)

      if group.status == "active" do
        rooms = Map.get(rooms_by_group, group.id, [])
        durable_cash_cents = Enum.sum(Enum.map(payments, & &1.amount_cents))

        legacy_cash_cents =
          max((group.cash_paid_cents || group.deposit_paid_cents || 0) - durable_cash_cents, 0)

        allocate_cash(group.id, rooms, nil, 0, legacy_cash_cents)

        Enum.each(payments, fn payment ->
          allocate_cash(
            group.id,
            rooms,
            payment.operation_id,
            payment.commit_order,
            payment.amount_cents
          )
        end)
      end
    end)

    backfill_active_credit_allocations(rooms_by_group)
  end

  defp load_groups do
    %{rows: rows} =
      repo().query!("""
      SELECT
        id,
        status,
        COALESCE(deposit_paid_cents, 0),
        COALESCE(cash_paid_cents, deposit_paid_cents, 0),
        COALESCE(refunded_cents, 0),
        COALESCE(retained_cents, 0),
        COALESCE(cash_converted_to_credit_cents, 0)
      FROM groups
      """)

    Enum.map(rows, fn [
                        id,
                        status,
                        deposit_paid_cents,
                        cash_paid_cents,
                        refunded_cents,
                        retained_cents,
                        converted_to_credit_cents
                      ] ->
      %{
        id: id,
        status: status,
        deposit_paid_cents: deposit_paid_cents,
        cash_paid_cents: cash_paid_cents,
        refunded_cents: refunded_cents,
        retained_cents: retained_cents,
        converted_to_credit_cents: converted_to_credit_cents
      }
    end)
  end

  defp load_rooms_by_group do
    %{rows: rows} =
      repo().query!("""
      SELECT id, group_pk_id, position, deposit_due_cents
      FROM group_rooms
      ORDER BY group_pk_id, position
      """)

    rows
    |> Enum.map(fn [id, group_pk_id, position, deposit_due_cents] ->
      %{
        id: id,
        group_pk_id: group_pk_id,
        position: position,
        deposit_due_cents: deposit_due_cents
      }
    end)
    |> Enum.group_by(& &1.group_pk_id)
  end

  defp load_applied_payments_by_group(groups) do
    group_ids = Map.new(groups, &{&1.id, true})

    %{rows: rows} =
      repo().query!("""
      SELECT
        partner_operations.id,
        partner_operations.operation_id,
        json_extract(partner_operations.result, '$.group_id'),
        json_extract(partner_operations.result, '$.amount_cents')
      FROM partner_operations
      WHERE operation_type = 'record_cash_payment'
        AND json_extract(result, '$.status') = 'applied'
      ORDER BY partner_operations.id
      """)

    rows
    |> Enum.map(fn [commit_order, operation_id, group_id, amount_cents] ->
      %{
        commit_order: commit_order,
        operation_id: operation_id,
        group_id: group_id,
        amount_cents: amount_cents
      }
    end)
    |> Enum.flat_map(fn payment ->
      case group_pk_id_for_partner_id(payment.group_id) do
        nil -> []
        group_pk_id -> [%{payment | group_id: group_pk_id}]
      end
    end)
    |> Enum.filter(&Map.has_key?(group_ids, &1.group_id))
    |> Enum.group_by(& &1.group_id)
  end

  defp group_pk_id_for_partner_id(group_id) do
    case repo().query!("SELECT id FROM groups WHERE group_id = ? LIMIT 1", [group_id]) do
      %{rows: [[id]]} -> id
      _result -> nil
    end
  end

  defp backfill_payment_dispositions(group, payments) do
    settlement = %{
      refunded_cents: group.refunded_cents,
      retained_cents: group.retained_cents,
      converted_to_credit_cents: group.converted_to_credit_cents
    }

    {_settlement, rows} =
      Enum.map_reduce(payments, settlement, fn payment, remaining ->
        {refunded, remaining} = take_from(remaining, :refunded_cents, payment.amount_cents)

        {retained, remaining} =
          take_from(remaining, :retained_cents, payment.amount_cents - refunded)

        {converted_to_credit, remaining} =
          take_from(
            remaining,
            :converted_to_credit_cents,
            payment.amount_cents - refunded - retained
          )

        row = %{
          payment_operation_id: payment.operation_id,
          recorded_cents: payment.amount_cents,
          refunded_cents: refunded,
          retained_cents: retained,
          converted_to_credit_cents: converted_to_credit
        }

        {row, remaining}
      end)

    Enum.each(rows, fn row ->
      insert_payment_disposition(group.id, row)
    end)
  end

  defp take_from(remaining, key, amount_cents) when amount_cents > 0 do
    taken = min(Map.fetch!(remaining, key), amount_cents)
    {taken, Map.update!(remaining, key, &(&1 - taken))}
  end

  defp take_from(remaining, _key, _amount_cents), do: {0, remaining}

  defp allocate_cash(_group_pk_id, _rooms, _operation_id, _funding_order, amount_cents)
       when amount_cents <= 0 do
    :ok
  end

  defp allocate_cash(group_pk_id, rooms, operation_id, funding_order, amount_cents) do
    Enum.reduce_while(rooms, amount_cents, fn room, amount_left ->
      room_allocated_cents =
        room_cash_allocated_cents(room.id) + room_credit_allocated_cents(room.id)

      available_cents = max(room.deposit_due_cents - room_allocated_cents, 0)
      amount_to_allocate = min(amount_left, available_cents)

      if amount_to_allocate > 0 do
        insert_cash_allocation(
          group_pk_id,
          room.id,
          operation_id,
          funding_order,
          amount_to_allocate
        )
      end

      case amount_left - amount_to_allocate do
        0 -> {:halt, 0}
        remaining -> {:cont, remaining}
      end
    end)
  end

  defp backfill_active_credit_allocations(rooms_by_group) do
    %{rows: rows} =
      repo().query!("""
      SELECT
        applied_hotel_credits.group_pk_id,
        applied_hotel_credits.hotel_credit_lot_id,
        applied_hotel_credits.amount_cents,
        applied_hotel_credits.inserted_at
      FROM applied_hotel_credits
      INNER JOIN groups ON groups.id = applied_hotel_credits.group_pk_id
      WHERE groups.status = 'active'
      ORDER BY applied_hotel_credits.inserted_at, applied_hotel_credits.id
      """)

    Enum.each(rows, fn [group_pk_id, hotel_credit_lot_id, amount_cents, _inserted_at] ->
      rooms = Map.get(rooms_by_group, group_pk_id, [])
      allocate_credit(group_pk_id, rooms, hotel_credit_lot_id, nil, 0, amount_cents)
    end)
  end

  defp allocate_credit(_group_pk_id, _rooms, _lot_id, _operation_id, _funding_order, amount_cents)
       when amount_cents <= 0 do
    :ok
  end

  defp allocate_credit(group_pk_id, rooms, lot_id, operation_id, funding_order, amount_cents) do
    Enum.reduce_while(rooms, amount_cents, fn room, amount_left ->
      room_allocated_cents =
        room_cash_allocated_cents(room.id) + room_credit_allocated_cents(room.id)

      available_cents = max(room.deposit_due_cents - room_allocated_cents, 0)
      amount_to_allocate = min(amount_left, available_cents)

      if amount_to_allocate > 0 do
        insert_credit_allocation(
          group_pk_id,
          room.id,
          lot_id,
          operation_id,
          funding_order,
          amount_to_allocate
        )
      end

      case amount_left - amount_to_allocate do
        0 -> {:halt, 0}
        remaining -> {:cont, remaining}
      end
    end)
  end

  defp room_cash_allocated_cents(room_id) do
    scalar!(
      "SELECT COALESCE(SUM(amount_cents), 0) FROM room_cash_allocations WHERE group_room_id = ?",
      [room_id]
    )
  end

  defp room_credit_allocated_cents(room_id) do
    scalar!(
      "SELECT COALESCE(SUM(amount_cents), 0) FROM room_credit_allocations WHERE group_room_id = ?",
      [room_id]
    )
  end

  defp insert_payment_disposition(group_pk_id, row) do
    repo().query!(
      """
      INSERT INTO payment_cash_dispositions (
        id,
        group_pk_id,
        payment_operation_id,
        recorded_cents,
        refunded_cents,
        retained_cents,
        converted_to_credit_cents,
        reduced_cents,
        charged_back_cents,
        charged_back,
        inserted_at,
        updated_at
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      """,
      [
        Ecto.UUID.generate(),
        group_pk_id,
        row.payment_operation_id,
        row.recorded_cents,
        row.refunded_cents,
        row.retained_cents,
        row.converted_to_credit_cents
      ]
    )
  end

  defp insert_cash_allocation(group_pk_id, room_id, operation_id, funding_order, amount_cents) do
    repo().query!(
      """
      INSERT INTO room_cash_allocations (
        id,
        group_pk_id,
        group_room_id,
        source_operation_id,
        amount_cents,
        funding_order,
        inserted_at,
        updated_at
      )
      VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      """,
      [Ecto.UUID.generate(), group_pk_id, room_id, operation_id, amount_cents, funding_order]
    )
  end

  defp insert_credit_allocation(
         group_pk_id,
         room_id,
         lot_id,
         operation_id,
         funding_order,
         amount_cents
       ) do
    repo().query!(
      """
      INSERT INTO room_credit_allocations (
        id,
        group_pk_id,
        group_room_id,
        hotel_credit_lot_id,
        application_operation_id,
        amount_cents,
        funding_order,
        inserted_at,
        updated_at
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      """,
      [
        Ecto.UUID.generate(),
        group_pk_id,
        room_id,
        lot_id,
        operation_id,
        amount_cents,
        funding_order
      ]
    )
  end

  defp scalar!(sql, params) do
    case repo().query!(sql, params) do
      %{rows: [[value]]} -> value
    end
  end
end
