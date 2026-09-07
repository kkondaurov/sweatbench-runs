defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    create table(:allocation_order) do
      add :kind, :text, null: false
      add :allocation_id, :integer, null: false
    end

    create unique_index(:allocation_order, [:kind, :allocation_id])

    create table(:transferred_payments, primary_key: false) do
      add :payment_operation_id, :text, primary_key: true
    end

    flush()
    GroupStay.RoomAccounting.OrderBackfill.run(repo())

    for {kind, table} <- [{"cash", "cash_allocations"}, {"credit", "credit_allocations"}] do
      execute """
      CREATE TRIGGER #{table}_order AFTER INSERT ON #{table}
      BEGIN
        INSERT INTO allocation_order (kind, allocation_id) VALUES ('#{kind}', NEW.id);
      END
      """

      execute """
      CREATE TRIGGER #{table}_order_delete AFTER DELETE ON #{table}
      BEGIN
        DELETE FROM allocation_order WHERE kind = '#{kind}' AND allocation_id = OLD.id;
      END
      """
    end
  end

  def down do
    for table <- ~w(cash_allocations credit_allocations) do
      execute "DROP TRIGGER #{table}_order"
      execute "DROP TRIGGER #{table}_order_delete"
    end

    drop table(:transferred_payments)
    drop table(:allocation_order)
  end
end
