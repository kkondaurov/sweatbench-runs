defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    for name <- [:cash_allocations, :credit_allocations] do
      alter table(name) do
        add :allocation_order, :integer, null: false, default: 0
      end
    end

    create table(:allocation_clock, primary_key: false) do
      add :value, :integer, null: false
    end

    create table(:transferred_payments, primary_key: false) do
      add :payment_operation_id, :string, primary_key: true
    end

    flush()

    # Before transfers, funding order is the senior cash/credit block followed
    # by durable funding commit order. Within each block, ids retain fill order.
    rows =
      repo().query!("""
      SELECT a.id, 'cash_allocations', coalesce(o.id, 0), 0
      FROM cash_allocations a LEFT JOIN operations o ON o.operation_id = a.payment_operation_id
      UNION ALL
      SELECT a.id, 'credit_allocations', coalesce(o.id, 0), 1
      FROM credit_allocations a LEFT JOIN operations o ON o.operation_id = a.operation_id
      ORDER BY 3, 4, 1
      """).rows

    for {[id, table, _, _], order} <- Enum.with_index(rows, 1) do
      repo().query!("UPDATE #{table} SET allocation_order = ? WHERE id = ?", [order, id])
    end

    repo().query!("INSERT INTO allocation_clock (value) VALUES (?)", [length(rows)])
  end

  def down do
    raise "Transferred funding cannot be represented by the previous release"
  end
end
