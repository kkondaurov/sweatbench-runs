defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    create table(:allocation_sequences) do
    end

    alter table(:cash_allocations) do
      add :transferred, :boolean, null: false, default: false
      add :allocation_order, :integer, null: false, default: 0
    end

    alter table(:credit_allocations) do
      add :allocation_order, :integer, null: false, default: 0
    end

    flush()
    backfill_allocation_order()
  end

  def down do
    drop table(:allocation_sequences)

    alter table(:credit_allocations) do
      remove :allocation_order
    end

    alter table(:cash_allocations) do
      remove :allocation_order
      remove :transferred
    end
  end

  defp backfill_allocation_order do
    next = assign_rows("cash_allocations", "payment_operation_id IS NULL", 0)
    next = assign_rows("credit_allocations", "operation_id IS NULL", next)

    operations =
      repo().query!("SELECT id, type, operation_id FROM operations ORDER BY id").rows

    next =
      Enum.reduce(operations, next, fn [_id, type, operation_id], next ->
        case type do
          "record_cash_payment" ->
            assign_rows("cash_allocations", "payment_operation_id = ?", next, [operation_id])

          "apply_hotel_credit" ->
            assign_rows("credit_allocations", "operation_id = ?", next, [operation_id])

          _ ->
            next
        end
      end)

    next = assign_rows("cash_allocations", "allocation_order = 0", next)
    next = assign_rows("credit_allocations", "allocation_order = 0", next)

    if next > 0 do
      repo().insert_all("allocation_sequences", Enum.map(1..next, &%{id: &1}))
    end
  end

  defp assign_rows(table, condition, next, params \\ []) do
    rows =
      repo().query!("SELECT id FROM #{table} WHERE #{condition} ORDER BY id", params).rows

    next =
      Enum.reduce(rows, next, fn [id], value ->
        value = value + 1
        repo().query!("UPDATE #{table} SET allocation_order = ? WHERE id = ?", [value, id])
        value
      end)

    next
  end
end
