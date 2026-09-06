defmodule GroupStay.Repo.Migrations.AddFinancePeriodCloses do
  use Ecto.Migration

  def change do
    alter table(:finance_reporting) do
      add :last_closed_on, :date
    end

    alter table(:finance_events) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    create table(:finance_closed_reports) do
      add :finance_reporting_id, references(:finance_reporting, on_delete: :delete_all),
        null: false

      add :report_date, :date, null: false
      add :data, :map, null: false
    end

    create unique_index(:finance_closed_reports, [:finance_reporting_id, :report_date])
  end
end
