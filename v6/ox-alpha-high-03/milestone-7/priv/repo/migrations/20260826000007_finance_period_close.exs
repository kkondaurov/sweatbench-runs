defmodule GroupStay.Repo.Migrations.FinancePeriodClose do
  use Ecto.Migration

  def up do
    alter table(:finance_report_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    create table(:finance_period_closes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :period_end_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_period_closes, [:period_end_on])

    create table(:finance_report_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :report_date, :date, null: false
      add :data, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_report_snapshots, [:report_date])
  end

  def down do
    drop table(:finance_report_snapshots)
    drop table(:finance_period_closes)

    alter table(:finance_report_movements) do
      remove :late_adjustment
    end
  end
end
