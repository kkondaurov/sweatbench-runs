defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def change do
    alter table(:finance_reporting_settings) do
      add :latest_period_end_on, :date
    end

    alter table(:finance_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    create table(:finance_closed_reports) do
      add :report_on, :date, null: false
      add :data, :map, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:finance_closed_reports, [:report_on])
  end
end
