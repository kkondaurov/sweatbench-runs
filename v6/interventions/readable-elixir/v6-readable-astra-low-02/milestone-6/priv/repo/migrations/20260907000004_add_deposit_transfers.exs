defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:cash_allocations), do: add(:allocation_order, :integer)
    alter table(:credit_allocations), do: add(:allocation_order, :integer)

    create table(:transferred_payments, primary_key: false) do
      add :payment_operation_id, :string, primary_key: true
    end

    create index(:cash_allocations, [:allocation_order])
    create index(:credit_allocations, [:allocation_order])
    flush()

    # Durable commit order is the funding chronology, not the partner's date.
    # Legacy cash precedes legacy credit, whose existing IDs preserve lot order.
    %{rows: rows} =
      repo().query!("""
      SELECT kind, allocation_id FROM (
        SELECT 'cash' AS kind, a.id AS allocation_id, p.id AS operation_order
        FROM cash_allocations a LEFT JOIN partner_operations p
          ON p.operation_id = a.payment_operation_id
        UNION ALL
        SELECT 'credit', a.id, p.id
        FROM credit_allocations a LEFT JOIN partner_operations p
          ON p.operation_id = a.operation_id
      ) ORDER BY COALESCE(operation_order, 0), kind, allocation_id
      """)

    for {[kind, id], order} <- Enum.with_index(rows, 1) do
      table = if kind == "cash", do: "cash_allocations", else: "credit_allocations"
      repo().query!("UPDATE #{table} SET allocation_order = ? WHERE id = ?", [order, id])
    end
  end

  def down do
    drop table(:transferred_payments)
    drop index(:cash_allocations, [:allocation_order])
    drop index(:credit_allocations, [:allocation_order])
    alter table(:credit_allocations), do: remove(:allocation_order)
    alter table(:cash_allocations), do: remove(:allocation_order)
  end
end
