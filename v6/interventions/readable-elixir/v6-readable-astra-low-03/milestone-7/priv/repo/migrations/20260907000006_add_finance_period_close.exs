defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def change do
    alter table(:finance_reporting) do
      add :closed_through, :date
    end

    alter table(:finance_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end
  end
end
