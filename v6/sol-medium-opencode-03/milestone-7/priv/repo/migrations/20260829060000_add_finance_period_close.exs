defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def change do
    create table(:finance_period_closes) do
      add :period_end_on, :date, null: false
      add :operation_record_cutoff_id, :integer, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_period_closes, [:period_end_on])

    alter table(:finance_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    alter table(:finance_credit_expiry_adjustments) do
      add :operation_id, :string
    end

    create index(:finance_credit_expiry_adjustments, [:operation_id])
  end
end
