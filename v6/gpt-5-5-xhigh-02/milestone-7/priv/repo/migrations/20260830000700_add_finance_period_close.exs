defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def change do
    create table(:finance_period_closes) do
      add :operation_id, :string, null: false
      add :period_end_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_period_closes, [:operation_id])
    create index(:finance_period_closes, [:period_end_on])

    create table(:finance_daily_reports) do
      add :report_date, :date, null: false
      add :closed_by_operation_id, :string, null: false
      add :data, :map, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_daily_reports, [:report_date])
    create index(:finance_daily_reports, [:closed_by_operation_id])

    alter table(:finance_cash_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    create index(:finance_cash_movements, [:posting_date, :late_adjustment])

    alter table(:finance_credit_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    create index(:finance_credit_movements, [:posting_date, :late_adjustment])
  end
end
