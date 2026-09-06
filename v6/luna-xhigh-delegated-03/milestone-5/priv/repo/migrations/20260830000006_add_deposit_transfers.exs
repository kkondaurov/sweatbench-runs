defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:cash_allocations) do
      add :allocation_order, :integer, null: false, default: 0
    end

    alter table(:credit_allocations) do
      add :allocation_order, :integer, null: false, default: 0
    end

    alter table(:payment_dispositions) do
      add :transferred, :boolean, null: false, default: false
    end

    # The reconstruction below uses direct queries, so make the queued
    # ALTER TABLE operations visible before reading the new columns.
    flush()

    # Existing rows predate the shared ordering column.  Reconstruct the
    # funding order from durable operation commit order, with the unattributed
    # legacy cash block before the unattributed legacy credit block.  The two
    # allocation tables have independent IDs, so arithmetic on those IDs
    # cannot represent the order across funding kinds.
    assign_existing_orders(repo())

    create index(:cash_allocations, [:group_id, :allocation_order])
    create index(:credit_allocations, [:group_id, :allocation_order])
  end

  def down do
    drop index(:credit_allocations, [:group_id, :allocation_order])
    drop index(:cash_allocations, [:group_id, :allocation_order])

    alter table(:payment_dispositions) do
      remove :transferred
    end

    alter table(:credit_allocations) do
      remove :allocation_order
    end

    alter table(:cash_allocations) do
      remove :allocation_order
    end
  end

  defp assign_existing_orders(repo) do
    next_order = assign_rows(repo, "cash_allocations", "payment_operation_id IS NULL", 0)

    next_order =
      assign_rows(repo, "credit_allocations", "source_operation_id IS NULL", next_order)

    records =
      repo.query!("SELECT operation_id, type FROM operation_records ORDER BY id").rows

    next_order =
      Enum.reduce(records, next_order, fn [operation_id, type], next_order ->
        case type do
          "record_cash_payment" ->
            assign_rows(repo, "cash_allocations", "payment_operation_id = ?", next_order, [
              operation_id
            ])

          "apply_hotel_credit" ->
            assign_rows(repo, "credit_allocations", "source_operation_id = ?", next_order, [
              operation_id
            ])

          _ ->
            next_order
        end
      end)

    # Keep manually-created or otherwise orphaned rows deterministic as well.
    next_order = assign_rows(repo, "cash_allocations", "allocation_order = 0", next_order)
    _next_order = assign_rows(repo, "credit_allocations", "allocation_order = 0", next_order)
  end

  defp assign_rows(repo, table, condition, next_order, params \\ []) do
    rows =
      repo.query!(
        "SELECT id FROM #{table} WHERE #{condition} ORDER BY id",
        params
      ).rows

    Enum.reduce(rows, next_order, fn [id], order ->
      repo.query!("UPDATE #{table} SET allocation_order = ? WHERE id = ?", [order + 1, id])
      order + 1
    end)
  end
end
