defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def change do
    alter table(:finance_reporting) do
      add :latest_closed_on, :date
    end

    create table(:finance_closed_reports, primary_key: false) do
      add :report_date, :date, primary_key: true
      add :report_json, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end
  end
end
