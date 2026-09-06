defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def up do
    alter table(:finance_reporting) do
      add :latest_closed_on, :date
    end

    alter table(:finance_cash_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    alter table(:finance_credit_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    create table(:finance_daily_reports) do
      add :finance_reporting_id, references(:finance_reporting, on_delete: :delete_all),
        null: false

      add :report_on, :date, null: false
      add :data, :map, null: false
    end

    create unique_index(:finance_daily_reports, [:finance_reporting_id, :report_on])
  end

  def down do
    drop table(:finance_daily_reports)

    alter table(:finance_credit_movements) do
      remove :late_adjustment
    end

    alter table(:finance_cash_movements) do
      remove :late_adjustment
    end

    alter table(:finance_reporting) do
      remove :latest_closed_on
    end
  end
end
