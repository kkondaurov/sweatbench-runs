defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    create table(:funding_allocation_orders) do
    end

    alter table(:cash_allocations) do
      add :allocation_order_id, references(:funding_allocation_orders, on_delete: :restrict)
    end

    alter table(:credit_allocations) do
      add :allocation_order_id, references(:funding_allocation_orders, on_delete: :restrict)
    end

    alter table(:cash_payments) do
      add :transfer_participated, :boolean, null: false, default: false
    end

    flush()
    backfill_allocation_order()

    create index(:cash_allocations, [:allocation_order_id])
    create index(:credit_allocations, [:allocation_order_id])
  end

  def down do
    drop index(:credit_allocations, [:allocation_order_id])
    drop index(:cash_allocations, [:allocation_order_id])

    alter table(:cash_payments) do
      remove :transfer_participated
    end

    alter table(:credit_allocations) do
      remove :allocation_order_id
    end

    alter table(:cash_allocations) do
      remove :allocation_order_id
    end

    drop table(:funding_allocation_orders)
  end

  # Before transfers, durable funding operations supplied the common ordering boundary between
  # cash and credit. Legacy funding used order zero, with its cash block ahead of credit. Preserve
  # that ordering while assigning the shared sequence used by transfers and later corrections.
  defp backfill_allocation_order do
    allocations = cash_allocations() ++ credit_allocations()

    allocations
    |> Enum.sort_by(fn allocation ->
      {allocation.group_id, allocation.funding_order, allocation.kind_order, allocation.id}
    end)
    |> Enum.each(&assign_order/1)
  end

  defp cash_allocations do
    %{rows: rows} =
      repo().query!("""
      SELECT allocation.id, payment.group_id, payment.funding_order
      FROM cash_allocations allocation
      JOIN cash_payments payment ON payment.id = allocation.cash_payment_id
      """)

    Enum.map(rows, fn [id, group_id, funding_order] ->
      %{
        table: "cash_allocations",
        id: id,
        group_id: group_id,
        funding_order: funding_order,
        kind_order: 0
      }
    end)
  end

  defp credit_allocations do
    %{rows: rows} =
      repo().query!("""
      SELECT allocation.id, allocation.group_id, COALESCE(operation.commit_order, 0)
      FROM credit_allocations allocation
      LEFT JOIN partner_operation_records operation
        ON operation.operation_id = allocation.funding_operation_id
      """)

    Enum.map(rows, fn [id, group_id, funding_order] ->
      %{
        table: "credit_allocations",
        id: id,
        group_id: group_id,
        funding_order: funding_order,
        kind_order: 1
      }
    end)
  end

  defp assign_order(allocation) do
    %{rows: [[order_id]]} =
      repo().query!("INSERT INTO funding_allocation_orders DEFAULT VALUES RETURNING id")

    repo().query!(
      "UPDATE #{allocation.table} SET allocation_order_id = ? WHERE id = ?",
      [order_id, allocation.id]
    )
  end
end
