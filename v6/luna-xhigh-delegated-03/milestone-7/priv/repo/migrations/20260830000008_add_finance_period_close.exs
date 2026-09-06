defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def change do
    alter table(:finance_postings) do
      add :original_posting_on, :date
    end

    execute "UPDATE finance_postings SET original_posting_on = posting_on"

    create table(:finance_period_closes) do
      add :period_end_on, :date, null: false
    end

    create unique_index(:finance_period_closes, [:period_end_on])

    create table(:finance_report_snapshots) do
      add :report_date, :date, null: false
      add :data, :text, null: false
    end

    create unique_index(:finance_report_snapshots, [:report_date])
  end
end
