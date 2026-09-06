defmodule GroupStay.Repo.Migrations.AddDepositTransferAccounting do
  use Ecto.Migration

  def up do
    alter table(:cash_room_allocations) do
      add :allocation_order, :integer, null: false, default: 0
    end

    alter table(:hotel_credit_applications) do
      add :allocation_order, :integer, null: false, default: 0
    end

    # Allocation ids belong to separate tables, so they cannot establish an order between cash
    # and credit.  This table is an application-wide sequence for funding allocations created
    # from this release onward.
    create table(:funding_allocation_orders) do
      timestamps(type: :utc_datetime)
    end

    create table(:cash_payment_transfer_participations) do
      add :payment_operation_id, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cash_payment_transfer_participations, [:payment_operation_id])

    # Earlier releases did not retain a cross-kind allocation sequence.  Give those allocations
    # a stable deterministic order, then advance the new sequence past the assigned values.
    execute("""
    WITH allocations AS (
      SELECT 'cash' AS kind, id, inserted_at, 0 AS kind_order
      FROM cash_room_allocations
      UNION ALL
      SELECT 'credit' AS kind, id, inserted_at, 1 AS kind_order
      FROM hotel_credit_applications
    ), ranked AS (
      SELECT kind, id,
             ROW_NUMBER() OVER (ORDER BY inserted_at, kind_order, id) AS allocation_order
      FROM allocations
    )
    UPDATE cash_room_allocations
    SET allocation_order = (
      SELECT allocation_order FROM ranked
      WHERE ranked.kind = 'cash' AND ranked.id = cash_room_allocations.id
    )
    WHERE id IN (SELECT id FROM ranked WHERE kind = 'cash')
    """)

    execute("""
    WITH allocations AS (
      SELECT 'cash' AS kind, id, inserted_at, 0 AS kind_order
      FROM cash_room_allocations
      UNION ALL
      SELECT 'credit' AS kind, id, inserted_at, 1 AS kind_order
      FROM hotel_credit_applications
    ), ranked AS (
      SELECT kind, id,
             ROW_NUMBER() OVER (ORDER BY inserted_at, kind_order, id) AS allocation_order
      FROM allocations
    )
    UPDATE hotel_credit_applications
    SET allocation_order = (
      SELECT allocation_order FROM ranked
      WHERE ranked.kind = 'credit' AND ranked.id = hotel_credit_applications.id
    )
    WHERE id IN (SELECT id FROM ranked WHERE kind = 'credit')
    """)

    execute("""
    INSERT INTO funding_allocation_orders (inserted_at, updated_at)
    SELECT CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM (
      SELECT id FROM cash_room_allocations
      UNION ALL
      SELECT id FROM hotel_credit_applications
    )
    """)
  end

  def down do
    drop table(:cash_payment_transfer_participations)
    drop table(:funding_allocation_orders)

    alter table(:hotel_credit_applications) do
      remove :allocation_order
    end

    alter table(:cash_room_allocations) do
      remove :allocation_order
    end
  end
end
