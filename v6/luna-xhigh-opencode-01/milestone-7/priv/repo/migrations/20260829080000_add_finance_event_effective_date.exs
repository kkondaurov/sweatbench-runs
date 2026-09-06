defmodule GroupStay.Repo.Migrations.AddFinanceEventEffectiveDate do
  use Ecto.Migration

  def change do
    alter table(:finance_events) do
      add :effective_on, :date
    end
  end
end
