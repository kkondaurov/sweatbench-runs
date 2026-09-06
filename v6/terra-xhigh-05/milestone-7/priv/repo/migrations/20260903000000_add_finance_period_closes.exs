defmodule GroupStay.Repo.Migrations.AddFinancePeriodCloses do
  use Ecto.Migration

  def change do
    create table(:finance_reporting_period_closes) do
      add :period_end_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_reporting_period_closes, [:period_end_on])

    # A close publishes the complete report payload rather than merely a
    # cutoff. This keeps both ordinary reporting and automatic expiry figures
    # immutable after later domain activity.
    create table(:finance_reporting_closed_daily_reports) do
      add :report_on, :date, null: false
      add :report_data, :map, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_reporting_closed_daily_reports, [:report_on])

    alter table(:finance_reporting_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    create index(:finance_reporting_movements, [:posting_on, :late_adjustment, :currency])
  end
end
