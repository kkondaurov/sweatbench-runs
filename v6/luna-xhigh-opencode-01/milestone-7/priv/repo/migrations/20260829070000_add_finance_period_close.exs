defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def change do
    alter table(:finance_reporting) do
      add :latest_closed_on, :date
    end

    alter table(:finance_events) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    create table(:finance_report_snapshots, primary_key: false) do
      add :report_date, :date, primary_key: true
      add :data, :text, null: false
    end
  end
end
