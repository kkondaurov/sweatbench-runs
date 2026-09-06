defmodule GroupStay.Repo.Migrations.BackfillRoomAccounting do
  use Ecto.Migration

  @disable_ddl_transaction true

  alias GroupStay.Operations

  def up do
    Operations.backfill_all_groups()
  end

  def down, do: :ok
end
