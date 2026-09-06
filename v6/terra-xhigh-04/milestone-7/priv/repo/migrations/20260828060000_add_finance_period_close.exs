defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def change do
    alter table(:finance_reporting_settings) do
      add :latest_closed_through_on, :date
    end

    alter table(:finance_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    alter table(:finance_credit_expiries) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    create index(:finance_movements, [:posting_on, :late_adjustment, :kind])

    create table(:finance_daily_report_snapshots) do
      add :report_on, :date, null: false
      add :data, :map, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_daily_report_snapshots, [:report_on])
  end
end
