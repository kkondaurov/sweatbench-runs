defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def change do
    alter table(:finance_reporting) do
      add :latest_close_on, :date
    end

    alter table(:finance_events) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    create table(:finance_report_snapshots) do
      add :report_on, :date, null: false
      add :data_json, :text, null: false
    end

    create unique_index(:finance_report_snapshots, [:report_on])
  end
end
