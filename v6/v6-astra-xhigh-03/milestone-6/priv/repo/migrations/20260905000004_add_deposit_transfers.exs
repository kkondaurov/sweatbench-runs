defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def change do
    alter table(:room_allocations) do
      # Retain participation even after every transferred cent is settled or corrected.
      add :transferred, :boolean, null: false, default: false
    end
  end
end
