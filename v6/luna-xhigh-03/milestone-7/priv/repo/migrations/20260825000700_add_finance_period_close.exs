defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def up do
    alter table(:finance_reporting) do
      add :latest_closed_on, :date
    end

    alter table(:finance_events) do
      add :original_posting_on, :date
    end

    execute "UPDATE finance_events SET original_posting_on = posting_on WHERE original_posting_on IS NULL"

    create table(:finance_report_snapshots, primary_key: false) do
      add :report_date, :date, primary_key: true
      add :data_json, :text, null: false
    end
  end

  def down do
    drop table(:finance_report_snapshots)

    alter table(:finance_events) do
      remove :original_posting_on
    end

    alter table(:finance_reporting) do
      remove :latest_closed_on
    end
  end
end
