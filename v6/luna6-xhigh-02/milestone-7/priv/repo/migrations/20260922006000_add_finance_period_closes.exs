defmodule GroupStay.Repo.Migrations.AddFinancePeriodCloses do
  use Ecto.Migration

  def change do
    alter table(:finance_cash_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    alter table(:finance_credit_events) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    create table(:finance_period_closes) do
      add :period_end_on, :date, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:finance_period_closes, [:period_end_on])

    create table(:finance_daily_report_snapshots) do
      add :date, :date, null: false
      add :data, :map, null: false
    end

    create unique_index(:finance_daily_report_snapshots, [:date])
  end
end
