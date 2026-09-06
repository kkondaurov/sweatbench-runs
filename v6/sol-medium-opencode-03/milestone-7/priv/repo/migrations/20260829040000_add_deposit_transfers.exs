defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    create table(:allocation_orders) do
      timestamps(type: :utc_datetime)
    end

    alter table(:cash_allocations) do
      add :allocation_order_id, references(:allocation_orders, on_delete: :delete_all)
    end

    alter table(:credit_allocations) do
      add :allocation_order_id, references(:allocation_orders, on_delete: :delete_all)
    end

    alter table(:cash_payments) do
      add :participated_in_transfer, :boolean, null: false, default: false
    end

    create table(:cash_dispositions) do
      add :cash_payment_id, references(:cash_payments, on_delete: :delete_all), null: false
      add :group_record_id, references(:groups, on_delete: :delete_all), null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cash_dispositions, [:cash_payment_id, :group_record_id])
    create index(:cash_dispositions, [:group_record_id])
    create unique_index(:cash_allocations, [:allocation_order_id])
    create unique_index(:credit_allocations, [:allocation_order_id])

    flush()
    backfill_allocation_orders()
    backfill_dispositions()
  end

  def down do
    drop table(:cash_dispositions)

    alter table(:cash_payments) do
      remove :participated_in_transfer
    end

    drop index(:credit_allocations, [:allocation_order_id])

    alter table(:credit_allocations) do
      remove :allocation_order_id
    end

    drop index(:cash_allocations, [:allocation_order_id])

    alter table(:cash_allocations) do
      remove :allocation_order_id
    end

    drop table(:allocation_orders)
  end

  defp backfill_allocation_orders do
    repo = repo()
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      repo.query!(
        """
        SELECT kind, allocation_id FROM (
          SELECT 'cash' AS kind, ca.id AS allocation_id, r.group_record_id,
                 CASE WHEN ca.cash_payment_id IS NULL THEN 0 ELSE 1 END AS legacy_rank,
                 COALESCE(op.id, 0) AS operation_rank, r.position, ca.id AS local_rank
          FROM cash_allocations ca
          JOIN rooms r ON r.id = ca.room_id
          LEFT JOIN cash_payments cp ON cp.id = ca.cash_payment_id
          LEFT JOIN operation_records op ON op.operation_id = cp.payment_operation_id
          UNION ALL
          SELECT 'credit' AS kind, ca.id AS allocation_id, r.group_record_id,
                 CASE WHEN ca.funding_operation_id IS NULL THEN 0 ELSE 1 END AS legacy_rank,
                 COALESCE(op.id, 0) AS operation_rank, r.position, ca.id AS local_rank
          FROM credit_allocations ca
          JOIN rooms r ON r.id = ca.room_id
          LEFT JOIN operation_records op ON op.operation_id = ca.funding_operation_id
        )
        ORDER BY group_record_id, legacy_rank, operation_rank, kind, position, local_rank
        """,
        []
      ).rows

    Enum.each(rows, fn [kind, allocation_id] ->
      order_id =
        repo.query!(
          "INSERT INTO allocation_orders (inserted_at, updated_at) VALUES (?, ?) RETURNING id",
          [now, now]
        ).rows
        |> hd()
        |> hd()

      table = if kind == "cash", do: "cash_allocations", else: "credit_allocations"

      repo.query!("UPDATE #{table} SET allocation_order_id = ? WHERE id = ?", [
        order_id,
        allocation_id
      ])
    end)
  end

  defp backfill_dispositions do
    repo = repo()
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    repo.query!(
      """
      INSERT INTO cash_dispositions
        (cash_payment_id, group_record_id, refunded_cents, retained_cents,
         converted_to_credit_cents, inserted_at, updated_at)
      SELECT id, group_record_id, refunded_cents, retained_cents,
             converted_to_credit_cents, ?, ?
      FROM cash_payments
      WHERE refunded_cents > 0 OR retained_cents > 0 OR converted_to_credit_cents > 0
      """,
      [now, now]
    )
  end
end
