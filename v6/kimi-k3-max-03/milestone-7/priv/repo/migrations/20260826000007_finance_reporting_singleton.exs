defmodule GroupStay.Repo.Migrations.FinanceReportingSingleton do
  use Ecto.Migration

  def change do
    # The reporting state holds at most one row; a constant marker column makes
    # that uniqueness enforceable so a lost concurrent-start race is rolled
    # back instead of creating a second inception.
    alter table(:finance_reporting) do
      add :singleton, :boolean, null: false, default: true
    end

    create unique_index(:finance_reporting, [:singleton])
  end
end
