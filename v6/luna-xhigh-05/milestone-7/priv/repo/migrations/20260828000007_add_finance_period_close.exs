defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def change do
    alter table(:finance_reporting) do
      add :latest_close_on, :date
    end

    alter table(:finance_events) do
      add :natural_posting_on, :date
    end

    create table(:finance_report_publications, primary_key: false) do
      add :report_date, :date, primary_key: true
      add :data_json, :text, null: false
    end
  end
end
