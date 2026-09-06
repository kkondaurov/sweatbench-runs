defmodule GroupStay.Repo.Migrations.AddDepositTransferTracking do
  use Ecto.Migration

  def change do
    alter table(:room_allocations) do
      add :transferred, :boolean, null: false, default: false
    end

    create index(:room_allocations, [:operation_id, :transferred])
  end
end
