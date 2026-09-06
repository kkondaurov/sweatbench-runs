defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:cash_sources) do
      add :transfer_participated, :boolean, null: false, default: false
    end

    alter table(:cash_allocations) do
      add :allocation_order, :integer, null: false, default: 0
    end

    alter table(:credit_allocations) do
      add :allocation_order, :integer, null: false, default: 0
    end

    create index(:cash_allocations, [:cash_source_id, :allocation_order])
    create index(:credit_allocations, [:credit_lot_id, :allocation_order])

    create table(:cash_dispositions) do
      add :cash_source_id, references(:cash_sources, on_delete: :restrict), null: false

      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :restrict),
          null: false

      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:cash_dispositions, [:cash_source_id])
    create index(:cash_dispositions, [:group_id])

    flush()
    backfill_allocation_order()
    backfill_dispositions()
  end

  def down do
    drop table(:cash_dispositions)

    drop index(:credit_allocations, [:credit_lot_id, :allocation_order])
    drop index(:cash_allocations, [:cash_source_id, :allocation_order])

    alter table(:credit_allocations) do
      remove :allocation_order
    end

    alter table(:cash_allocations) do
      remove :allocation_order
    end

    alter table(:cash_sources) do
      remove :transfer_participated
    end
  end

  defp backfill_allocation_order do
    cash =
      query!("""
      SELECT a.id, s.payment_operation_id, COALESCE(s.funding_order, 0), r.position
      FROM cash_allocations a
      JOIN cash_sources s ON s.id = a.cash_source_id
      JOIN rooms r ON r.id = a.room_id
      """)
      |> rows_as([:id, :operation_id, :operation_order, :room_position])
      |> Enum.map(fn allocation ->
        key =
          if is_nil(allocation.operation_id),
            do: {0, 0, allocation.room_position, allocation.id},
            else: {2, allocation.operation_order, allocation.room_position, allocation.id}

        {:cash_allocations, allocation.id, key}
      end)

    credit =
      query!("""
      SELECT a.id, a.funding_operation_id, p.id, r.position
      FROM credit_allocations a
      LEFT JOIN partner_operations p ON p.operation_id = a.funding_operation_id
      JOIN rooms r ON r.id = a.room_id
      """)
      |> rows_as([:id, :operation_id, :operation_order, :room_position])
      |> Enum.map(fn allocation ->
        key =
          if is_nil(allocation.operation_id),
            do: {1, 0, allocation.room_position, allocation.id},
            else: {2, allocation.operation_order, allocation.room_position, allocation.id}

        {:credit_allocations, allocation.id, key}
      end)

    (cash ++ credit)
    |> Enum.sort_by(&elem(&1, 2))
    |> Enum.with_index(1)
    |> Enum.each(fn {{table, id, _key}, order} ->
      query!("UPDATE #{table} SET allocation_order = ? WHERE id = ?", [order, id])
    end)
  end

  defp backfill_dispositions do
    query!("""
    INSERT INTO cash_dispositions (cash_source_id, group_id, kind, amount_cents)
    SELECT id, group_id, 'refunded', refunded_cents FROM cash_sources WHERE refunded_cents > 0
    UNION ALL
    SELECT id, group_id, 'retained', retained_cents FROM cash_sources WHERE retained_cents > 0
    UNION ALL
    SELECT id, group_id, 'converted', converted_to_credit_cents
    FROM cash_sources WHERE converted_to_credit_cents > 0
    """)
  end

  defp rows_as(result, keys), do: Enum.map(result.rows, &Map.new(Enum.zip(keys, &1)))
  defp query!(sql, params \\ []), do: repo().query!(sql, params)
end
