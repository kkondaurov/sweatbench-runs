defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def change do
    alter table(:finance_movements) do
      add :late, :boolean, default: false, null: false
    end

    create table(:finance_period_closes) do
      add :operation_id, :string, null: false
      add :period_end_on, :date, null: false

      timestamps()
    end

    create index(:finance_period_closes, [:period_end_on])

    create table(:finance_report_snapshots) do
      add :report_date, :date, null: false
      add :data, :string, null: false

      timestamps()
    end

    create unique_index(:finance_report_snapshots, [:report_date])
  end
end
