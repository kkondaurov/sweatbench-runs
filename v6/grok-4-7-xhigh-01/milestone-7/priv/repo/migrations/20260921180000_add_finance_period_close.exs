defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def change do
    alter table(:finance_reporting) do
      add :closed_through, :date
    end

    alter table(:finance_movements) do
      add :late, :boolean, null: false, default: false
    end

    create table(:finance_published_reports) do
      add :report_on, :date, null: false
      add :payload, :text, null: false
      add :closing_liability_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_published_reports, [:report_on])
  end
end
