defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def change do
    create table(:finance_period_closes) do
      add :operation_id, :string, null: false
      add :period_end_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_period_closes, [:operation_id])
    create unique_index(:finance_period_closes, [:period_end_on])

    create table(:finance_closed_daily_reports) do
      add :report_date, :date, null: false
      add :data_json, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_closed_daily_reports, [:report_date])

    alter table(:finance_cash_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    alter table(:finance_credit_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end
  end
end
