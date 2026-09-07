defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def change do
    alter table(:finance_reporting_periods) do
      add :latest_closed_on, :date
    end

    alter table(:finance_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    create table(:finance_report_snapshots) do
      add :reporting_period_id,
          references(:finance_reporting_periods, on_delete: :delete_all),
          null: false

      add :report_date, :date, null: false
      add :data, :map, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:finance_report_snapshots, [:reporting_period_id, :report_date])
  end
end
