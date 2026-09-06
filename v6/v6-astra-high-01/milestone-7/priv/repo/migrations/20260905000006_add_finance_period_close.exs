defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def change do
    alter table(:finance_entries) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    create index(:operations, [:type],
             where: "type = 'close_finance_period'",
             name: :operations_finance_close_index
           )
  end
end
