defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:payment_dispositions) do
      add :participated_in_transfer, :boolean, null: false, default: false
    end

    alter table(:room_allocations) do
      add :creation_order, :integer, null: false, default: 0
    end

    flush()

    # Earlier releases allocated funding one group at a time, so the
    # group-local fill positions carry each row's allocation order. Number
    # existing rows globally so reductions across groups can walk them in
    # reverse allocation order.
    execute("""
    UPDATE room_allocations
    SET creation_order = (
      SELECT COUNT(*)
      FROM room_allocations AS earlier
      WHERE earlier.group_id < room_allocations.group_id
         OR (earlier.group_id = room_allocations.group_id
             AND earlier.fill_position < room_allocations.fill_position)
         OR (earlier.group_id = room_allocations.group_id
             AND earlier.fill_position = room_allocations.fill_position
             AND earlier.id < room_allocations.id)
    ) + 1
    """)
  end

  def down do
    alter table(:room_allocations) do
      remove :creation_order
    end

    alter table(:payment_dispositions) do
      remove :participated_in_transfer
    end
  end
end
