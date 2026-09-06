defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def up do
    alter table(:finance_reporting) do
      add :latest_close_on, :date
    end

    alter table(:finance_report_movements) do
      add :occurred_on, :date
    end

    execute "UPDATE finance_report_movements SET occurred_on = posting_date"

    create table(:finance_report_snapshots, primary_key: false) do
      add :report_date, :date, primary_key: true
      add :data_json, :text, null: false
    end
  end

  def down do
    drop table(:finance_report_snapshots)

    alter table(:finance_report_movements) do
      remove :occurred_on
    end

    alter table(:finance_reporting) do
      remove :latest_close_on
    end
  end
end
