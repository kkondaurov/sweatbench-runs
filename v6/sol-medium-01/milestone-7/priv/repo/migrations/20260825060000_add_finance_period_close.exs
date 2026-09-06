defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def change do
    alter table(:finance_reporting) do
      add :latest_closed_on, :date
    end

    alter table(:finance_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    create table(:finance_daily_report_snapshots) do
      add :finance_reporting_id, references(:finance_reporting, on_delete: :delete_all),
        null: false

      add :report_on, :date, null: false
      add :data, :map, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:finance_daily_report_snapshots, [
             :finance_reporting_id,
             :report_on
           ])
  end
end
