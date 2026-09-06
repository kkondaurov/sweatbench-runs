defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def change do
    alter table(:room_allocations) do
      # The creation order of allocation rows across all groups. Once a
      # payment's held funding spans several groups after a deposit transfer,
      # reductions and chargebacks remove it in reverse creation order across
      # all of them.
      add :seq, :integer, null: false, default: 0
    end

    # Carried-over rows keep their within-group order; rows of different
    # groups never mix until a transfer moves them, and transfers assign
    # fresh global sequence numbers from that point on.
    execute(backfill_allocation_seq(), "")

    alter table(:operation_records) do
      # Set once any funding of a recorded cash payment has participated in a
      # deposit transfer; the payment's statement then reports its held cash
      # group by group.
      add :funding_transferred, :boolean, null: false, default: false
    end
  end

  defp backfill_allocation_seq do
    """
    WITH ordered AS (
      SELECT id,
             ROW_NUMBER() OVER (ORDER BY group_id, position, id) - 1 AS rn
      FROM room_allocations
    )
    UPDATE room_allocations
    SET seq = (SELECT rn FROM ordered WHERE ordered.id = room_allocations.id)
    """
  end
end
