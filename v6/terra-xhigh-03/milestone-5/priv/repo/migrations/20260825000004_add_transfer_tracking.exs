defmodule GroupStay.Repo.Migrations.AddTransferTracking do
  use Ecto.Migration

  def change do
    alter table(:room_funding_allocations) do
      add :has_been_transferred, :boolean, null: false, default: false
    end
  end
end
