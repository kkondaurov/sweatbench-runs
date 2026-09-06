defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:cash_allocations) do
      add :transferred, :boolean, null: false, default: false
    end

    alter table(:hotel_credit_applications) do
      add :allocation_order, :integer, null: false, default: 0
    end

    execute("""
    WITH ordered_allocations AS (
      SELECT
        kind,
        id,
        ROW_NUMBER() OVER (
          ORDER BY inserted_at, existing_order, kind, id
        ) - 1 AS new_order
      FROM (
        SELECT
          'cash' AS kind,
          id,
          inserted_at,
          allocation_order AS existing_order
        FROM cash_allocations
        UNION ALL
        SELECT
          'credit' AS kind,
          id,
          inserted_at,
          allocation_order AS existing_order
        FROM hotel_credit_applications
      )
    )
    UPDATE cash_allocations
    SET allocation_order = (
      SELECT new_order
      FROM ordered_allocations
      WHERE ordered_allocations.kind = 'cash'
        AND ordered_allocations.id = cash_allocations.id
    )
    WHERE EXISTS (
      SELECT 1
      FROM ordered_allocations
      WHERE ordered_allocations.kind = 'cash'
        AND ordered_allocations.id = cash_allocations.id
    )
    """)

    execute("""
    WITH ordered_allocations AS (
      SELECT
        kind,
        id,
        ROW_NUMBER() OVER (
          ORDER BY inserted_at, existing_order, kind, id
        ) - 1 AS new_order
      FROM (
        SELECT
          'cash' AS kind,
          id,
          inserted_at,
          allocation_order AS existing_order
        FROM cash_allocations
        UNION ALL
        SELECT
          'credit' AS kind,
          id,
          inserted_at,
          allocation_order AS existing_order
        FROM hotel_credit_applications
      )
    )
    UPDATE hotel_credit_applications
    SET allocation_order = (
      SELECT new_order
      FROM ordered_allocations
      WHERE ordered_allocations.kind = 'credit'
        AND ordered_allocations.id = hotel_credit_applications.id
    )
    WHERE EXISTS (
      SELECT 1
      FROM ordered_allocations
      WHERE ordered_allocations.kind = 'credit'
        AND ordered_allocations.id = hotel_credit_applications.id
    )
    """)

    create index(:cash_allocations, [:transferred])
    create index(:hotel_credit_applications, [:group_reservation_id, :allocation_order])
  end

  def down do
    drop index(:hotel_credit_applications, [:group_reservation_id, :allocation_order])
    drop index(:cash_allocations, [:transferred])

    alter table(:hotel_credit_applications) do
      remove :allocation_order
    end

    alter table(:cash_allocations) do
      remove :transferred
    end
  end
end
