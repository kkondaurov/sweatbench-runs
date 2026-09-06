defmodule GroupStay.Repo.Migrations.AddFinancePeriodCloses do
  use Ecto.Migration

  def change do
    create table(:finance_reporting_period_closes) do
      add :period_end_on, :date, null: false
      add :source_operation_id, :string, null: false
    end

    create unique_index(:finance_reporting_period_closes, [:period_end_on])

    create table(:finance_reporting_closed_reports) do
      add :report_date, :date, null: false
      add :data, :map, null: false
    end

    create unique_index(:finance_reporting_closed_reports, [:report_date])

    alter table(:finance_reporting_entries) do
      add :late_adjustment, :boolean, null: false, default: false
    end
  end
end
