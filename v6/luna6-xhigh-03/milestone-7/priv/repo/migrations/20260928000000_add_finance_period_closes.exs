defmodule GroupStay.Repo.Migrations.AddFinancePeriodCloses do
  use Ecto.Migration

  def change do
    alter table(:finance_reporting) do
      add :closed_through_on, :date
    end

    alter table(:finance_report_entries) do
      add :late_adjustment, :boolean, null: false, default: false
    end
  end
end
