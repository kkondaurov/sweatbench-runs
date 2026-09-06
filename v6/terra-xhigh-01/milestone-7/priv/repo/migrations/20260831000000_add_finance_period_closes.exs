defmodule GroupStay.Repo.Migrations.AddFinancePeriodCloses do
  use Ecto.Migration

  def change do
    alter table(:finance_reporting_settings) do
      add :closed_through_on, :date
    end

    alter table(:finance_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    create table(:finance_daily_reports) do
      add :finance_reporting_id, references(:finance_reporting_settings, on_delete: :delete_all),
        null: false

      add :report_on, :date, null: false
      add :data, :map, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_daily_reports, [:finance_reporting_id, :report_on])
  end
end
