defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:room_allocations) do
      add :transferred, :boolean, null: false, default: false
      add :global_sequence, :integer, null: false, default: 0
    end

    flush()
    GroupStay.Funding.backfill_global_sequences()
  end

  def down do
    alter table(:room_allocations) do
      remove :global_sequence
      remove :transferred
    end
  end
end
