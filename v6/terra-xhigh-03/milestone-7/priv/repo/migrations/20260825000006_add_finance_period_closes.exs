defmodule GroupStay.Repo.Migrations.AddFinancePeriodCloses do
  use Ecto.Migration

  def change do
    alter table(:finance_reporting_settings) do
      add :closed_through_on, :date
    end

    alter table(:finance_reporting_events) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    create table(:finance_reporting_closed_reports) do
      add :report_date, :date, null: false
      add :data, :map, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_reporting_closed_reports, [:report_date])
  end
end
