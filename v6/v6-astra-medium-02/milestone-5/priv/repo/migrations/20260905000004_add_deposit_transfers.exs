defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def change do
    alter table(:room_funding) do
      add :transferred, :boolean, null: false, default: false
    end
  end
end
