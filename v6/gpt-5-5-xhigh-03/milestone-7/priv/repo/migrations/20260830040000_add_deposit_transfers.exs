defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def change do
    alter table(:cash_fundings) do
      add :transfer_participated, :boolean, null: false, default: false
    end
  end
end
