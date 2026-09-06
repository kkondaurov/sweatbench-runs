defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:room_allocations) do
      add :transferred, :boolean, null: false, default: false
    end
  end

  def down do
    alter table(:room_allocations) do
      remove :transferred
    end
  end
end
