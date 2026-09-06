defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def change do
    alter table(:cash_allocations) do
      add :allocation_order, :integer
    end

    alter table(:hotel_credit_allocations) do
      add :allocation_order, :integer
    end

    alter table(:cash_payments) do
      add :transferred, :boolean, null: false, default: false
    end

    create index(:cash_allocations, [:allocation_order])
    create index(:hotel_credit_allocations, [:allocation_order])

    create table(:allocation_sequences, primary_key: false) do
      add :id, :integer, primary_key: true
      add :next_order, :integer, null: false, default: 0
    end

    execute(
      "INSERT INTO allocation_sequences (id, next_order) VALUES (1, 0)",
      "DELETE FROM allocation_sequences WHERE id = 1"
    )

    execute(
      fn ->
        GroupStay.Groups.backfill_allocation_order()
      end,
      fn ->
        :ok
      end
    )
  end
end
