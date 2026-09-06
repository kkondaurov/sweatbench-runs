defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  import Ecto.Query

  def up do
    # A globally comparable creation order for room allocations, so a
    # payment's held allocations can be removed in reverse order even after a
    # transfer spread them across groups.
    alter table(:room_allocations) do
      add :sequence, :integer, null: false, default: 0
    end

    alter table(:payments) do
      add :transferred, :boolean, null: false, default: false
    end

    flush()

    backfill_sequences()
  end

  def down do
    alter table(:payments) do
      remove :transferred
    end

    alter table(:room_allocations) do
      remove :sequence
    end
  end

  # Allocations written before this release belong to a single group each, so
  # any order that respects each group's positions is a valid global order.
  defp backfill_sequences do
    repo().all(
      from(a in "room_allocations",
        order_by: [asc: a.group_id, asc: a.position],
        select: %{id: a.id}
      )
    )
    |> Enum.with_index(1)
    |> Enum.each(fn {row, sequence} ->
      repo().query!("UPDATE room_allocations SET sequence = ? WHERE id = ?", [sequence, row.id])
    end)
  end
end
