defmodule GroupStay.Repo.Migrations.AddFinancePeriodCloses do
  use Ecto.Migration

  def change do
    create table(:finance_period_closes, primary_key: false) do
      add :period_end_on, :date, primary_key: true
      add :operation_id, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:finance_period_closes, [:operation_id])

    alter table(:finance_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end
  end
end
