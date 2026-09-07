defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def up do
    # Reporting is opt-in. Upgrading does not invent an inception date or replay
    # legacy operations; the start operation captures the deployed balances.
    create table(:finance_reporting_starts, primary_key: false) do
      add :id, :integer, primary_key: true
      add :operation_id, :string, null: false
      add :starts_on, :date, null: false
    end

    create table(:finance_entries) do
      add :operation_id, :string, null: false
      add :account, :string, null: false
      add :property_id, :string
      add :credit_lot_id, references(:credit_lots)
      add :posted_on, :date, null: false
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:finance_entries, [:posted_on])
    create index(:finance_entries, [:operation_id])
  end

  def down do
    # The journal would still replay the original start after a re-upgrade,
    # but its opening position cannot be reconstructed from today's balances.
    if repo().query!("SELECT id FROM finance_reporting_starts LIMIT 1").rows != [] do
      raise Ecto.MigrationError, "cannot remove finance reporting after inception"
    end

    drop table(:finance_entries)
    drop table(:finance_reporting_starts)
  end
end
