defmodule GroupStay.Repo.Migrations.BackfillRoomAccounting do
  use Ecto.Migration

  def up do
    GroupStay.RoomAccountingBackfill.run(repo())
  end

  def down, do: :ok
end
