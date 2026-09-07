defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def up do
    alter table(:finance_reporting) do
      add :closed_through, :date
    end

    alter table(:finance_entries) do
      add :late_adjustment, :boolean, null: false, default: false
    end
  end

  def down do
    if repo().query!("SELECT id FROM finance_reporting WHERE closed_through IS NOT NULL").rows !=
         [] do
      raise Ecto.MigrationError,
        message:
          "closed finance periods require a forward migration; downgrade would unpublish reports"
    end

    alter table(:finance_entries) do
      remove :late_adjustment
    end

    alter table(:finance_reporting) do
      remove :closed_through
    end
  end
end
