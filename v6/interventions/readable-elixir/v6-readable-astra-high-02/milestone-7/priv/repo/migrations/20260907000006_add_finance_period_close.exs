defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def change do
    create table(:finance_period_closes) do
      add :operation_id, :string, null: false
      add :period_end_on, :date, null: false
    end

    create unique_index(:finance_period_closes, [:period_end_on])
    create unique_index(:finance_period_closes, [:operation_id])

    alter table(:finance_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end
  end
end
