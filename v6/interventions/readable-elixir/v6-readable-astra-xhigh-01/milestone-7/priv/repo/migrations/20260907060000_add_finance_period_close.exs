defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def up do
    create table(:finance_period_closes) do
      add :operation_id, :string, null: false
      add :period_end_on, :date, null: false
    end

    create unique_index(:finance_period_closes, [:operation_id])
    create unique_index(:finance_period_closes, [:period_end_on])

    alter table(:finance_reporting_entries) do
      add :late_adjustment, :boolean, null: false, default: false
    end
  end

  def down do
    # A replay cannot restore a removed close, and the previous release could
    # post into published days. Preserve the boundary and its classifications.
    if repo().query!("SELECT id FROM finance_period_closes LIMIT 1").rows != [] do
      raise Ecto.MigrationError, message: "cannot downgrade after a finance period closes"
    end

    alter table(:finance_reporting_entries) do
      remove :late_adjustment
    end

    drop table(:finance_period_closes)
  end
end
