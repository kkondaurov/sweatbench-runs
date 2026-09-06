defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def change do
    alter table(:finance_inception) do
      add :closed_through, :date
    end

    alter table(:finance_movements) do
      add :late, :boolean, null: false, default: false
    end
  end
end
