defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    create table(:allocation_orders) do
    end

    alter table(:room_cash_allocations) do
      add :allocation_order, :integer
    end

    alter table(:room_credit_allocations) do
      add :allocation_order, :integer
    end

    alter table(:cash_payments) do
      add :participated_in_transfer, :boolean, null: false, default: false
    end

    flush()
    backfill_allocation_orders()

    create index(:room_cash_allocations, [:allocation_order])
    create index(:room_credit_allocations, [:allocation_order])
  end

  def down do
    alter table(:cash_payments) do
      remove :participated_in_transfer
    end

    alter table(:room_credit_allocations) do
      remove :allocation_order
    end

    alter table(:room_cash_allocations) do
      remove :allocation_order
    end

    drop table(:allocation_orders)
  end

  defp backfill_allocation_orders do
    %{rows: operation_rows} =
      repo().query!("SELECT operation_id, id FROM operation_records ORDER BY id")

    operation_order = Map.new(operation_rows, fn [operation_id, id] -> {operation_id, id} end)

    allocations = cash_allocations() ++ credit_allocations()

    allocations
    |> Enum.sort_by(fn allocation ->
      {
        allocation.group_id,
        if(is_nil(allocation.funding_operation_id), do: 0, else: 1),
        Map.get(operation_order, allocation.funding_operation_id, 0),
        allocation.legacy_kind,
        allocation.id
      }
    end)
    |> Enum.each(fn allocation ->
      %{rows: [[order]]} =
        repo().query!("INSERT INTO allocation_orders DEFAULT VALUES RETURNING id")

      repo().query!(
        "UPDATE #{allocation.table} SET allocation_order = ? WHERE id = ?",
        [order, allocation.id]
      )
    end)
  end

  defp cash_allocations do
    %{rows: rows} =
      repo().query!(
        "SELECT id, group_id, funding_operation_id FROM room_cash_allocations ORDER BY id"
      )

    Enum.map(rows, fn [id, group_id, funding_operation_id] ->
      %{
        table: "room_cash_allocations",
        id: id,
        group_id: group_id,
        funding_operation_id: funding_operation_id,
        legacy_kind: 0
      }
    end)
  end

  defp credit_allocations do
    %{rows: rows} =
      repo().query!(
        "SELECT id, group_id, funding_operation_id FROM room_credit_allocations ORDER BY id"
      )

    Enum.map(rows, fn [id, group_id, funding_operation_id] ->
      %{
        table: "room_credit_allocations",
        id: id,
        group_id: group_id,
        funding_operation_id: funding_operation_id,
        legacy_kind: 1
      }
    end)
  end
end
