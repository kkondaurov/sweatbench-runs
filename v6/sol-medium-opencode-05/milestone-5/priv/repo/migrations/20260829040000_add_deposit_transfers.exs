defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:fundings) do
      add :participated_in_transfer, :boolean, null: false, default: false
    end

    alter table(:room_allocations) do
      add :allocation_order, :integer, null: false, default: 0
    end

    execute("""
    WITH ordered AS (
      SELECT room_allocations.id,
             ROW_NUMBER() OVER (
               ORDER BY fundings.inserted_at, fundings.group_ref, fundings.funding_order,
                        rooms.position, room_allocations.id
             ) AS allocation_order
      FROM room_allocations
      JOIN fundings ON fundings.id = room_allocations.funding_id
      JOIN rooms ON rooms.id = room_allocations.room_id
    )
    UPDATE room_allocations
    SET allocation_order = (
      SELECT ordered.allocation_order FROM ordered WHERE ordered.id = room_allocations.id
    )
    """)

    drop unique_index(:room_allocations, [:room_id, :funding_id])
    create index(:room_allocations, [:room_id, :funding_id])
    create unique_index(:room_allocations, [:allocation_order])
  end

  def down do
    drop unique_index(:room_allocations, [:allocation_order])
    drop index(:room_allocations, [:room_id, :funding_id])

    execute("""
    UPDATE room_allocations
    SET amount_cents = (
      SELECT SUM(duplicates.amount_cents)
      FROM room_allocations AS duplicates
      WHERE duplicates.room_id = room_allocations.room_id
        AND duplicates.funding_id = room_allocations.funding_id
    )
    WHERE id = (
      SELECT MIN(keeper.id)
      FROM room_allocations AS keeper
      WHERE keeper.room_id = room_allocations.room_id
        AND keeper.funding_id = room_allocations.funding_id
    )
    """)

    execute("""
    DELETE FROM room_allocations
    WHERE id != (
      SELECT MIN(keeper.id)
      FROM room_allocations AS keeper
      WHERE keeper.room_id = room_allocations.room_id
        AND keeper.funding_id = room_allocations.funding_id
    )
    """)

    create unique_index(:room_allocations, [:room_id, :funding_id])

    alter table(:room_allocations) do
      remove :allocation_order
    end

    alter table(:fundings) do
      remove :participated_in_transfer
    end
  end
end
