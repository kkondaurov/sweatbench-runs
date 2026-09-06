defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  alias GroupStay.Groups.Backfill

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_cents, :integer
      add :deposit_due_cents, :integer
    end

    alter table(:groups) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :clawback_cents, :integer, null: false, default: 0
    end

    create table(:room_allocations) do
      add :group_id,
          references(:groups, type: :string, column: :group_id, on_delete: :delete_all),
          null: false

      add :room_id, references(:rooms, column: :id, on_delete: :delete_all), null: false
      add :operation_id, :string
      add :lot_id, references(:credit_lots, column: :id, on_delete: :delete_all)
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
      add :disposition, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:room_allocations, [:group_id])
    create index(:room_allocations, [:room_id])
    create index(:room_allocations, [:operation_id])
    create index(:room_allocations, [:lot_id])

    create table(:credit_entitlements) do
      add :lot_id, references(:credit_lots, column: :id, on_delete: :delete_all), null: false
      add :operation_id, :string, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_entitlements, [:lot_id])
    create index(:credit_entitlements, [:operation_id])

    flush()

    Backfill.backfill_all()
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:room_allocations)

    alter table(:credit_lots) do
      remove :clawback_cents
    end

    alter table(:groups) do
      remove :cash_charged_back_cents
      remove :cash_reduced_cents
    end

    alter table(:rooms) do
      remove :deposit_due_cents
      remove :lodging_cents
      remove :status
    end
  end
end
