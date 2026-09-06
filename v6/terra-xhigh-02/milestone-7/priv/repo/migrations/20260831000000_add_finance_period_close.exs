defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def change do
    alter table(:finance_cash_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    alter table(:finance_credit_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    create table(:finance_period_closes) do
      add :period_end_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_period_closes, [:period_end_on])

    create table(:finance_daily_reports, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :reporting_start_id, references(:finance_reporting_starts, on_delete: :delete_all),
        null: false

      add :report_date, :date, null: false
      add :data_json, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_daily_reports, [:reporting_start_id, :report_date])
  end
end
