defmodule GroupStay.Repo.Migrations.AddFinancePeriodCloses do
  use Ecto.Migration

  def change do
    create table(:finance_period_closes) do
      add :period_end_on, :date, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_period_closes, [:period_end_on])

    create table(:finance_report_snapshots) do
      add :report_on, :date, null: false
      add :data, :map, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_report_snapshots, [:report_on])

    alter table(:finance_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end
  end
end
