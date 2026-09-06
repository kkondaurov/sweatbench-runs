defmodule GroupStay.Repo.Migrations.AddDepositTransferMetadata do
  use Ecto.Migration

  def up do
    alter table(:cash_allocations) do
      add :legacy_funding_group_id, :string
      add :allocation_order, :integer, null: false, default: 0
    end

    alter table(:credit_allocations) do
      add :allocation_order, :integer, null: false, default: 0
    end

    alter table(:cash_payments) do
      add :transfer_participated, :boolean, null: false, default: false
    end

    flush()

    backfill_legacy_sources()
    backfill_allocation_order()
  end

  def down do
    alter table(:cash_payments) do
      remove :transfer_participated
    end

    alter table(:credit_allocations) do
      remove :allocation_order
    end

    alter table(:cash_allocations) do
      remove :allocation_order
      remove :legacy_funding_group_id
    end
  end

  defp backfill_legacy_sources do
    repo().query!(
      """
      UPDATE cash_allocations
      SET legacy_funding_group_id = group_id
      WHERE payment_operation_id IS NULL AND legacy_funding_group_id IS NULL
      """,
      []
    )
  end

  defp backfill_allocation_order do
    cash_allocations =
      rows(
        "SELECT id, group_id, payment_operation_id FROM cash_allocations ORDER BY id",
        [:id, :group_id, :operation_id],
        "cash_allocations",
        0
      )

    credit_allocations =
      rows(
        "SELECT id, group_id, funding_operation_id FROM credit_allocations ORDER BY id",
        [:id, :group_id, :operation_id],
        "credit_allocations",
        1
      )

    operation_orders =
      repo().query!(
        "SELECT operation_id, id FROM operation_records",
        []
      ).rows
      |> Map.new(fn [operation_id, id] -> {operation_id, id} end)

    allocations =
      (cash_allocations ++ credit_allocations)
      |> Enum.sort_by(fn allocation ->
        case Map.get(operation_orders, allocation.operation_id) do
          nil -> {0, allocation.group_id, allocation.kind, allocation.id}
          commit_order -> {1, commit_order, allocation.id}
        end
      end)

    Enum.with_index(allocations, 1)
    |> Enum.each(fn {allocation, order} ->
      repo().query!(
        "UPDATE #{allocation.table} SET allocation_order = ? WHERE id = ?",
        [order, allocation.id]
      )
    end)
  end

  defp rows(sql, columns, table, kind) do
    repo().query!(sql, []).rows
    |> Enum.map(fn row ->
      Map.merge(Map.new(Enum.zip(columns, row)), %{table: table, kind: kind})
    end)
  end
end
