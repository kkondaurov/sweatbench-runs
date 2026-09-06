defmodule GroupStay.Repo.Migrations.FinancePeriodClose do
  use Ecto.Migration

  def change do
    alter table(:finance_reporting) do
      add :period_end_on, :date
    end

    alter table(:finance_movements) do
      add :natural_posting_date, :date
      add :late, :boolean, null: false, default: false
    end

    create table(:finance_closed_reports, primary_key: false) do
      add :date, :date, primary_key: true
      add :payload, :text, null: false

      timestamps(type: :utc_datetime)
    end
  end
end
