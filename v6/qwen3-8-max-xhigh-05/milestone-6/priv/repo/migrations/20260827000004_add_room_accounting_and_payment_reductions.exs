defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :deposit_due_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    alter table(:ledger) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:room_allocations) do
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :funding_operation_id, :string
      add :lot_id, references(:credit_lots, type: :binary_id)
      add :amount_cents, :integer, null: false
      add :status, :string, null: false, default: "held"

      timestamps(type: :utc_datetime)
    end

    create index(:room_allocations, [:room_id, :status])
    create index(:room_allocations, [:funding_operation_id, :status])
    create index(:room_allocations, [:lot_id])

    flush()

    GroupStay.Migrations.RoomAccountingBackfill.run()
  end

  def down do
    drop table(:room_allocations)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:ledger) do
      remove :cash_charged_back_cents
      remove :cash_reduced_cents
    end

    alter table(:rooms) do
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :deposit_due_cents
      remove :status
    end
  end
end
