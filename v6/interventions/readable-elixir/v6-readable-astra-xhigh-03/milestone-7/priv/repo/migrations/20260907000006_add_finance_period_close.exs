defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def up do
    create table(:finance_period_closes) do
      add :operation_id, :string, null: false
      add :period_end_on, :date, null: false
    end

    create unique_index(:finance_period_closes, [:period_end_on])

    alter table(:finance_entries) do
      add :late_adjustment, :boolean, null: false, default: false
    end
  end

  def down do
    # Removing the cutoff would let new entries change published reports, while
    # the operation journal would still replay a successful close.
    if repo().query!("SELECT id FROM finance_period_closes LIMIT 1").rows != [] do
      raise Ecto.MigrationError, "cannot remove finance period close after publication"
    end

    alter table(:finance_entries) do
      remove :late_adjustment
    end

    drop table(:finance_period_closes)
  end
end
