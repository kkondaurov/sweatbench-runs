defmodule GroupStay.Repo.Migrations.AddDepositTransferTracking do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :durable_cash_accounting, :boolean, null: false, default: false
    end

    alter table(:payment_accountings) do
      add :transferred, :boolean, null: false, default: false
    end

    execute("""
    UPDATE groups
    SET durable_cash_accounting = 1
    WHERE group_id IN (SELECT DISTINCT group_id FROM payment_accountings)
    """)
  end

  def down do
    alter table(:payment_accountings) do
      remove :transferred
    end

    alter table(:groups) do
      remove :durable_cash_accounting
    end
  end
end
