defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def change do
    alter table(:finance_reporting) do
      add :closed_through, :date
    end

    alter table(:finance_cash_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    alter table(:finance_credit_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    create table(:finance_closed_reports) do
      add :report_date, :date, null: false
      add :data, :map, null: false
    end

    create unique_index(:finance_closed_reports, [:report_date])
  end
end
