defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    create table(:allocation_orders) do
      add :kind, :string, null: false
      add :allocation_id, :integer, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:allocation_orders, [:kind, :allocation_id])

    create table(:payment_transfer_participations) do
      add :cash_payment_id, references(:cash_payments, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:payment_transfer_participations, [:cash_payment_id])

    create table(:cash_settlements) do
      add :cash_payment_id, references(:cash_payments, on_delete: :delete_all), null: false

      add :group_reservation_id, references(:group_reservations, on_delete: :restrict),
        null: false

      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:cash_settlements, [:cash_payment_id, :group_reservation_id])
    create index(:cash_settlements, [:group_reservation_id])

    execute("""
    INSERT INTO allocation_orders (kind, allocation_id, inserted_at, updated_at)
    SELECT kind, allocation_id, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM (
      SELECT
        'cash' AS kind,
        allocation.id AS allocation_id,
        CASE
          WHEN operation.id IS NULL THEN 0
          ELSE operation.id + 2
        END AS funding_order,
        room.position AS room_position
      FROM cash_allocations AS allocation
      JOIN cash_payments AS payment ON payment.id = allocation.cash_payment_id
      JOIN group_rooms AS room ON room.id = allocation.group_room_id
      LEFT JOIN partner_operations AS operation ON operation.operation_id = payment.operation_id
      UNION ALL
      SELECT
        'credit' AS kind,
        allocation.id AS allocation_id,
        CASE
          WHEN allocation.funding_operation_id IS NULL THEN 1
          ELSE operation.id + 2
        END AS funding_order,
        room.position AS room_position
      FROM credit_allocations AS allocation
      JOIN group_rooms AS room ON room.id = allocation.group_room_id
      LEFT JOIN partner_operations AS operation
        ON operation.operation_id = allocation.funding_operation_id
    )
    ORDER BY funding_order, room_position, kind, allocation_id
    """)

    execute("""
    INSERT INTO cash_settlements (
      cash_payment_id,
      group_reservation_id,
      refunded_cents,
      retained_cents,
      converted_to_credit_cents,
      inserted_at,
      updated_at
    )
    SELECT
      id,
      group_reservation_id,
      refunded_cents,
      retained_cents,
      converted_to_credit_cents,
      CURRENT_TIMESTAMP,
      CURRENT_TIMESTAMP
    FROM cash_payments
    WHERE refunded_cents > 0 OR retained_cents > 0 OR converted_to_credit_cents > 0
    """)
  end

  def down do
    drop table(:cash_settlements)
    drop table(:payment_transfer_participations)
    drop table(:allocation_orders)
  end
end
