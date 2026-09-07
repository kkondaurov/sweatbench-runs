defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:cash_allocations) do
      add :allocation_order, :integer, null: false, default: 0
      add :transferred, :boolean, null: false, default: false
    end

    alter table(:room_credit_allocations) do
      add :allocation_order, :integer, null: false, default: 0
    end

    flush()

    # Earlier releases have separate cash and credit IDs. Reconstruct their
    # interleaving from durable funding commit order, with each group's legacy
    # senior block first. Dates and partner identifier sorting are not clocks.
    # Use storage directly so future schema changes cannot affect this upgrade.
    recorded =
      rows("""
      SELECT operation_id, id, type FROM operation_records
      WHERE type IN ('record_cash_payment', 'apply_hotel_credit')
        AND json_extract(result, '$.status') = 'applied'
      """)
      |> Map.new(&{{&1["type"], &1["operation_id"]}, &1["id"]})

    cash =
      rows("SELECT id, group_id, payment_operation_id FROM cash_allocations")
      |> Enum.map(fn allocation ->
        commit = Map.get(recorded, {"record_cash_payment", allocation["payment_operation_id"]})
        rank = if commit, do: {2, commit, 0}, else: {0, 0, 0}
        {"cash_allocations", allocation, rank}
      end)

    credit =
      rows("""
      SELECT room.id, room.group_id, redemption.id AS redemption_id, redemption.operation_id
      FROM room_credit_allocations AS room
      JOIN credit_allocations AS redemption ON redemption.id = room.credit_allocation_id
      """)
      |> Enum.map(fn allocation ->
        commit = Map.get(recorded, {"apply_hotel_credit", allocation["operation_id"]})
        redemption = allocation["redemption_id"]
        rank = if commit, do: {2, commit, redemption}, else: {1, redemption, 0}
        {"room_credit_allocations", allocation, rank}
      end)

    (cash ++ credit)
    |> Enum.sort_by(fn {_, allocation, rank} ->
      {allocation["group_id"], rank, allocation["id"]}
    end)
    |> Enum.with_index(1)
    |> Enum.each(fn {{table, allocation, _}, order} ->
      repo().query!("UPDATE #{table} SET allocation_order = ? WHERE id = ?", [
        order,
        allocation["id"]
      ])
    end)

    create unique_index(:cash_allocations, [:allocation_order])
    create unique_index(:room_credit_allocations, [:allocation_order])
  end

  def down do
    if rows("""
       SELECT id FROM operation_records
       WHERE type = 'transfer_deposit' AND json_extract(result, '$.status') = 'applied'
       LIMIT 1
       """) != [] do
      raise Ecto.MigrationError,
            "cannot remove deposit transfers after funding has moved between groups"
    end

    drop unique_index(:cash_allocations, [:allocation_order])
    drop unique_index(:room_credit_allocations, [:allocation_order])

    alter table(:cash_allocations) do
      remove :allocation_order
      remove :transferred
    end

    alter table(:room_credit_allocations) do
      remove :allocation_order
    end
  end

  defp rows(sql) do
    %{columns: columns, rows: rows} = repo().query!(sql)
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end
end
