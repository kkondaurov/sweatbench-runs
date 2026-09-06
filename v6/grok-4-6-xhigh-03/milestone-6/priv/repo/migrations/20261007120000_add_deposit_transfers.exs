defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def change do
    alter table(:payment_statements) do
      add :transfer_participated, :boolean, null: false, default: false
      add :settlement_by_group, :map, default: %{}
    end
  end
end
