defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    create table(:cash_allocations) do
      add :group_id, references(:groups, column: :group_id, type: :text), null: false
      add :room_id, :text
      add :payment_operation_id, :text
      add :amount_cents, :integer, null: false
      add :disposition, :text, null: false
      add :lot_id, references(:credit_lots)
      add :entitlement_cents, :integer, null: false, default: 0
    end

    create index(:cash_allocations, [:payment_operation_id])
    create index(:cash_allocations, [:group_id])

    alter table(:credit_allocations) do
      add :room_id, :text
    end

    alter table(:credit_lots) do
      add :unrecovered_cents, :integer, null: false, default: 0
    end

    flush()
    GroupStay.RoomAccounting.Backfill.run(repo())
  end

  def down do
    drop table(:cash_allocations)
    alter table(:credit_allocations), do: remove(:room_id)
    alter table(:credit_lots), do: remove(:unrecovered_cents)
  end
end
