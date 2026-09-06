defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:cash_allocations) do
      add :allocation_order, :integer, null: false, default: 0
      add :transferred, :boolean, null: false, default: false
    end

    alter table(:credit_allocations) do
      add :allocation_order, :integer, null: false, default: 0
    end

    create table(:allocation_sequence, primary_key: false) do
      add :value, :integer, null: false
    end

    flush()

    # Earlier releases have separate cash and credit IDs. Recover their combined
    # funding order from the durable commit order, with legacy cash then credit
    # preceding recorded funding. Within each funding operation, IDs preserve fill order.
    allocations =
      repo().query!("""
      SELECT a.kind, a.id FROM (
        SELECT 'cash' AS kind, id, payment_operation_id AS operation_id FROM cash_allocations
        UNION ALL
        SELECT 'credit' AS kind, id, operation_id FROM credit_allocations
      ) a LEFT JOIN operations o ON o.operation_id = a.operation_id
      ORDER BY CASE WHEN o.id IS NULL THEN 0 ELSE 1 END, o.id, a.kind, a.id
      """)

    for {[kind, id], order} <- Enum.with_index(allocations.rows, 1) do
      repo().query!("UPDATE #{kind}_allocations SET allocation_order = ? WHERE id = ?", [
        order,
        id
      ])
    end

    repo().query!("INSERT INTO allocation_sequence (value) VALUES (?)", [length(allocations.rows)])
  end

  def down do
    drop table(:allocation_sequence)
    alter table(:credit_allocations), do: remove(:allocation_order)

    alter table(:cash_allocations) do
      remove :allocation_order
      remove :transferred
    end
  end
end
