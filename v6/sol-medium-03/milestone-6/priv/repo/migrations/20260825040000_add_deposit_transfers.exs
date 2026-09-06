defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:cash_allocations) do
      add :allocation_sequence, :integer
    end

    alter table(:credit_allocations) do
      add :allocation_sequence, :integer
    end

    alter table(:cash_payments) do
      add :transfer_participated, :boolean, null: false, default: false
    end

    flush()
    backfill_allocation_sequences()

    create index(:cash_allocations, [:allocation_sequence])
    create index(:credit_allocations, [:allocation_sequence])
  end

  def down do
    drop index(:credit_allocations, [:allocation_sequence])
    drop index(:cash_allocations, [:allocation_sequence])

    alter table(:cash_payments) do
      remove :transfer_participated
    end

    alter table(:credit_allocations) do
      remove :allocation_sequence
    end

    alter table(:cash_allocations) do
      remove :allocation_sequence
    end
  end

  defp backfill_allocation_sequences do
    operation_order =
      sql!("SELECT operation_id, id FROM partner_operations").rows
      |> Map.new(fn [operation_id, id] -> {operation_id, id} end)

    cash =
      sql!("SELECT id, group_id, payment_operation_id FROM cash_allocations").rows
      |> Enum.map(fn [id, group_id, operation_id] ->
        %{table: "cash_allocations", id: id, group_id: group_id, operation_id: operation_id}
      end)

    credit =
      sql!("SELECT id, group_id, funding_operation_id FROM credit_allocations").rows
      |> Enum.map(fn [id, group_id, operation_id] ->
        %{table: "credit_allocations", id: id, group_id: group_id, operation_id: operation_id}
      end)

    (cash ++ credit)
    |> Enum.sort_by(fn allocation ->
      legacy_rank =
        case {allocation.operation_id, allocation.table} do
          {nil, "cash_allocations"} -> 0
          {nil, "credit_allocations"} -> 1
          _ -> 2
        end

      {allocation.group_id, legacy_rank, Map.get(operation_order, allocation.operation_id, 0),
       allocation.id}
    end)
    |> Enum.with_index(1)
    |> Enum.each(fn {allocation, sequence} ->
      sql!("UPDATE #{allocation.table} SET allocation_sequence = ? WHERE id = ?", [
        sequence,
        allocation.id
      ])
    end)
  end

  defp sql!(statement, params \\ []), do: Ecto.Adapters.SQL.query!(repo(), statement, params)
end
