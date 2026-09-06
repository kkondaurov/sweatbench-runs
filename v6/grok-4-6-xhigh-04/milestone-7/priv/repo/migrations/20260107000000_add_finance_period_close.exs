defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def up do
    alter table(:finance_reporting) do
      add :closed_through_on, :date
    end

    alter table(:finance_events) do
      add :late_adjustment, :boolean, null: false, default: false
    end
  end

  def down do
    alter table(:finance_events) do
      remove :late_adjustment
    end

    alter table(:finance_reporting) do
      remove :closed_through_on
    end
  end
end
