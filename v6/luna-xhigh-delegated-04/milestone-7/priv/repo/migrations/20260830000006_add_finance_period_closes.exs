defmodule GroupStay.Repo.Migrations.AddFinancePeriodCloses do
  use Ecto.Migration

  def change do
    alter table(:finance_events) do
      add :late_cash_json, :text, null: false, default: "{}"
      add :late_credit_json, :text, null: false, default: "{}"
    end

    create table(:finance_period_closes) do
      add :period_end_on, :date, null: false
    end

    create unique_index(:finance_period_closes, [:period_end_on])

    create table(:finance_reports) do
      add :report_date, :date, null: false
      add :report_json, :text, null: false
      add :status, :string, null: false, default: "closed"
    end

    create unique_index(:finance_reports, [:report_date])
  end
end
