defmodule GroupStay.Repo.Migrations.AddFinancePeriodCloses do
  use Ecto.Migration

  def change do
    create table(:finance_period_closes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :operation_id, :string, null: false
      add :period_end_on, :date, null: false

      timestamps(updated_at: false, type: :utc_datetime)
    end

    create unique_index(:finance_period_closes, [:operation_id])
    create unique_index(:finance_period_closes, [:period_end_on])

    alter table(:finance_operation_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end
  end
end
