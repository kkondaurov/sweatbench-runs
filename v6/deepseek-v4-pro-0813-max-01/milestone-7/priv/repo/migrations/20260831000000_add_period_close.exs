defmodule GroupStay.Repo.Migrations.AddPeriodClose do
  use Ecto.Migration

  def up do
    alter table(:finance_movements) do
      add :is_late, :boolean, null: false, default: false
    end

    create table(:finance_period_closes, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :period_end_on, :date, null: false

      timestamps()
    end

    create table(:finance_report_snapshots, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :report_date, :date, null: false
      add :data, :map, null: false

      timestamps()
    end

    create unique_index(:finance_report_snapshots, [:report_date])
  end

  def down do
    drop table(:finance_report_snapshots)
    drop table(:finance_period_closes)

    alter table(:finance_movements) do
      remove :is_late
    end
  end
end
