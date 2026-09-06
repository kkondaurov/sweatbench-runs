defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def change do
    alter table(:funding_allocations) do
      add :transferred, :boolean, null: false, default: false
    end
  end
end
