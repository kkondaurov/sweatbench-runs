defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def change do
    alter table(:finance_reporting_settings) do
      add :latest_closed_on_day, :integer
    end

    alter table(:finance_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    alter table(:finance_credit_expiry_adjustments) do
      add :late_adjustment, :boolean, null: false, default: false
    end
  end
end
