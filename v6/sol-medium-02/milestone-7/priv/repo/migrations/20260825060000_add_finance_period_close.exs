defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def change do
    create table(:finance_period_closes) do
      add :period_end_on, :date, null: false

      add :partner_operation_id, references(:partner_operations, on_delete: :restrict),
        null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:finance_period_closes, [:period_end_on])
    create unique_index(:finance_period_closes, [:partner_operation_id])

    alter table(:finance_cash_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    alter table(:finance_credit_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end
  end
end
