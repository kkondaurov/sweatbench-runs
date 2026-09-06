defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def change do
    alter table(:finance_reportings) do
      add :closed_through, :date
    end

    alter table(:finance_cash_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    alter table(:finance_credit_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end
  end
end
