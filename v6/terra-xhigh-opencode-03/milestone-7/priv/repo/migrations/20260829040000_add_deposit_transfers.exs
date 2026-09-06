defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS allocation_orders (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      allocation_type TEXT NOT NULL,
      allocation_db_id TEXT NOT NULL,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS allocation_orders_allocation_type_allocation_db_id_index
    ON allocation_orders (allocation_type, allocation_db_id)
    """)

    unless column_exists?("cash_payments", "transfer_participated") do
      alter table(:cash_payments) do
        add :transfer_participated, :boolean, null: false, default: false
      end
    end

    alter table(:room_cash_allocations) do
      add :allocation_order_id, references(:allocation_orders), null: true
    end

    alter table(:room_credit_allocations) do
      add :allocation_order_id, references(:allocation_orders), null: true
    end

    create index(:room_cash_allocations, [:allocation_order_id])
    create index(:room_credit_allocations, [:allocation_order_id])

    create table(:cash_payment_dispositions) do
      add :payment_operation_id, :string, null: false
      add :group_db_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :disposition, :string, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cash_payment_dispositions, [
             :payment_operation_id,
             :group_db_id,
             :disposition
           ])

    execute("""
    INSERT OR IGNORE INTO allocation_orders (allocation_type, allocation_db_id, inserted_at, updated_at)
    SELECT allocation_type, allocation_db_id, inserted_at, updated_at
    FROM (
      SELECT 'cash' AS allocation_type, CAST(id AS TEXT) AS allocation_db_id, inserted_at, updated_at
      FROM room_cash_allocations
      UNION ALL
      SELECT 'credit' AS allocation_type, id AS allocation_db_id, inserted_at, updated_at
      FROM room_credit_allocations
    )
    ORDER BY inserted_at, allocation_type, allocation_db_id
    """)

    execute("""
    UPDATE room_cash_allocations
    SET allocation_order_id = (
      SELECT id
      FROM allocation_orders
      WHERE allocation_type = 'cash'
        AND allocation_db_id = CAST(room_cash_allocations.id AS TEXT)
    )
    """)

    execute("""
    UPDATE room_credit_allocations
    SET allocation_order_id = (
      SELECT id
      FROM allocation_orders
      WHERE allocation_type = 'credit'
        AND allocation_db_id = room_credit_allocations.id
    )
    """)
  end

  def down do
    drop table(:cash_payment_dispositions)

    drop index(:room_credit_allocations, [:allocation_order_id])
    drop index(:room_cash_allocations, [:allocation_order_id])

    alter table(:room_credit_allocations) do
      remove :allocation_order_id
    end

    alter table(:room_cash_allocations) do
      remove :allocation_order_id
    end
  end

  defp column_exists?(table, column) do
    {:ok, %{rows: rows}} = Ecto.Adapters.SQL.query(GroupStay.Repo, "PRAGMA table_info(#{table})")

    Enum.any?(rows, fn [_position, name | _details] -> name == column end)
  end
end
