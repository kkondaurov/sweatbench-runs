defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:credit_allocations) do
      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all)
      add :order_lo, :integer
    end

    create index(:credit_allocations, [:room_id])

    create table(:cash_allocations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all), null: false

      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :nilify_all)

      add :operation_id, :string
      add :amount_cents, :integer, null: false
      add :sequence, :integer, null: false
      add :order_lo, :integer
      add :disposition, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:cash_allocations, [:group_id, :sequence])
    create index(:cash_allocations, [:room_id, :disposition])
    create index(:cash_allocations, [:operation_id])
    create index(:cash_allocations, [:credit_lot_id])

    flush()

    GroupStay.Funding.Backfill.run()
  end

  def down do
    drop table(:cash_allocations)

    alter table(:credit_allocations) do
      remove :room_id
      remove :order_lo
    end

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:rooms) do
      remove :status
      remove :lodging_cents
      remove :deposit_due_cents
    end
  end
end
