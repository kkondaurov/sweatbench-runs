defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def change do
    create table(:finance_period_closes) do
      add :operation_id, :string, null: false
      add :period_end_on, :date, null: false

      timestamps()
    end

    create unique_index(:finance_period_closes, [:period_end_on])

    create table(:finance_closed_reports) do
      add :date, :date, null: false
      add :data, :map, null: false

      timestamps()
    end

    create unique_index(:finance_closed_reports, [:date])

    alter table(:finance_movements) do
      add :late, :boolean, null: false, default: false
    end
  end
end
