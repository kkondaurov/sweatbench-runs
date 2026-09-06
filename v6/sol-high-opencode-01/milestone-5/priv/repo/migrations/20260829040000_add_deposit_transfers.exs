defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    create table(:deposit_allocation_sequences) do
    end

    alter table(:cash_allocations) do
      add :allocation_order, references(:deposit_allocation_sequences)
    end

    alter table(:credit_allocations) do
      add :allocation_order, references(:deposit_allocation_sequences)
    end

    create unique_index(:cash_allocations, [:allocation_order])
    create unique_index(:credit_allocations, [:allocation_order])

    alter table(:payment_accounts) do
      add :participated_in_transfer, :boolean, null: false, default: false
    end

    create table(:payment_dispositions) do
      add :payment_operation_id,
          references(:payment_accounts,
            column: :payment_operation_id,
            type: :string,
            on_delete: :delete_all
          ),
          null: false

      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :delete_all),
          null: false

      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
    end

    create unique_index(:payment_dispositions, [:payment_operation_id, :group_id])
    create index(:payment_dispositions, [:group_id])

    flush()
    backfill_allocation_order()

    execute("""
    CREATE TRIGGER cash_allocations_require_unique_global_order_insert
    BEFORE INSERT ON cash_allocations
    WHEN NEW.allocation_order IS NULL OR
         EXISTS (SELECT 1 FROM credit_allocations WHERE allocation_order = NEW.allocation_order)
    BEGIN
      SELECT RAISE(ABORT, 'invalid cash allocation order');
    END
    """)

    execute("""
    CREATE TRIGGER cash_allocations_require_unique_global_order_update
    BEFORE UPDATE OF allocation_order ON cash_allocations
    WHEN NEW.allocation_order IS NULL OR
         EXISTS (SELECT 1 FROM credit_allocations WHERE allocation_order = NEW.allocation_order)
    BEGIN
      SELECT RAISE(ABORT, 'invalid cash allocation order');
    END
    """)

    execute("""
    CREATE TRIGGER credit_allocations_require_unique_global_order_insert
    BEFORE INSERT ON credit_allocations
    WHEN NEW.allocation_order IS NULL OR
         EXISTS (SELECT 1 FROM cash_allocations WHERE allocation_order = NEW.allocation_order)
    BEGIN
      SELECT RAISE(ABORT, 'invalid credit allocation order');
    END
    """)

    execute("""
    CREATE TRIGGER credit_allocations_require_unique_global_order_update
    BEFORE UPDATE OF allocation_order ON credit_allocations
    WHEN NEW.allocation_order IS NULL OR
         EXISTS (SELECT 1 FROM cash_allocations WHERE allocation_order = NEW.allocation_order)
    BEGIN
      SELECT RAISE(ABORT, 'invalid credit allocation order');
    END
    """)

    execute("""
    INSERT INTO payment_dispositions
      (payment_operation_id, group_id, refunded_cents, retained_cents, converted_to_credit_cents)
    SELECT payment_operation_id, group_id, refunded_cents, retained_cents, converted_to_credit_cents
    FROM payment_accounts
    WHERE refunded_cents > 0 OR retained_cents > 0 OR converted_to_credit_cents > 0
    """)
  end

  def down do
    execute("DROP TRIGGER credit_allocations_require_unique_global_order_update")
    execute("DROP TRIGGER credit_allocations_require_unique_global_order_insert")
    execute("DROP TRIGGER cash_allocations_require_unique_global_order_update")
    execute("DROP TRIGGER cash_allocations_require_unique_global_order_insert")

    drop table(:payment_dispositions)

    alter table(:payment_accounts) do
      remove :participated_in_transfer
    end

    drop index(:credit_allocations, [:allocation_order])
    drop index(:cash_allocations, [:allocation_order])

    alter table(:credit_allocations) do
      remove :allocation_order
    end

    alter table(:cash_allocations) do
      remove :allocation_order
    end

    drop table(:deposit_allocation_sequences)
  end

  defp backfill_allocation_order do
    repo = repo()

    assign_rows(repo, "cash_allocations", "payment_operation_id IS NULL", [])
    assign_rows(repo, "credit_allocations", "funding_operation_id IS NULL", [])

    query!(
      repo,
      "SELECT operation_id, operation_type FROM partner_operations " <>
        "WHERE operation_type IN ('record_cash_payment', 'apply_hotel_credit') ORDER BY id"
    )
    |> Enum.each(fn
      [operation_id, "record_cash_payment"] ->
        assign_rows(repo, "cash_allocations", "payment_operation_id = ?", [operation_id])

      [operation_id, "apply_hotel_credit"] ->
        assign_rows(repo, "credit_allocations", "funding_operation_id = ?", [operation_id])
    end)

    assign_rows(repo, "cash_allocations", "allocation_order IS NULL", [])
    assign_rows(repo, "credit_allocations", "allocation_order IS NULL", [])
  end

  defp assign_rows(repo, table, condition, params) do
    query!(repo, "SELECT id FROM #{table} WHERE #{condition} ORDER BY id", params)
    |> Enum.each(fn [id] ->
      [[allocation_order]] =
        query!(repo, "INSERT INTO deposit_allocation_sequences DEFAULT VALUES RETURNING id")

      query!(repo, "UPDATE #{table} SET allocation_order = ? WHERE id = ?", [allocation_order, id])
    end)
  end

  defp query!(repo, sql, params \\ []), do: repo.query!(sql, params).rows
end
