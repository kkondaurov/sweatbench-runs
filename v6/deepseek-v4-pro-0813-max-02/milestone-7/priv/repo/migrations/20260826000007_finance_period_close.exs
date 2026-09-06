defmodule GroupStay.Repo.Migrations.FinancePeriodClose do
  use Ecto.Migration

  def up do
    alter table(:finance_movements) do
      add :late, :boolean, null: false, default: false
    end

    create table(:finance_period_closes) do
      add :period_end_on, :date, null: false

      timestamps()
    end

    create unique_index(:finance_period_closes, [:period_end_on])

    create table(:finance_report_snapshots) do
      add :report_date, :date, null: false
      add :data, :text, null: false
    end

    create unique_index(:finance_report_snapshots, [:report_date])
  end

  def down do
    drop table(:finance_report_snapshots)
    drop table(:finance_period_closes)

    alter table(:finance_movements) do
      remove :late
    end
  end
end
