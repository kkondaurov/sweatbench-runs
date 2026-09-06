defmodule GroupStay.Repo.Migrations.BackfillRoomAccounting do
  use Ecto.Migration

  # The backfill runs after the transfer allocation-order schema is installed.
  def up, do: :ok

  def down, do: :ok
end
