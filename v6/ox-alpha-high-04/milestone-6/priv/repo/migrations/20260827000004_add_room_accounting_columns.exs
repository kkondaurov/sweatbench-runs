defmodule GroupStay.Repo.Migrations.AddRoomAccountingColumns do
  use Ecto.Migration

  def change do
    # Rooms carry their own deposit requirement and funding status so group
    # totals can describe the active rooms only.
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :deposit_due_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    # One row per piece of a room's deposit: which funding (a recorded
    # payment operation, or unattributed funding from before durable
    # operation records) contributed it and where that cash or credit sits
    # now. The auto-increment id preserves the fill order used by room
    # accounting.
    create table(:deposit_dispositions) do
      add :group_id, :string, null: false
      add :room_id, :string
      add :payment_operation_id, :string
      add :fund, :string, null: false
      add :kind, :string, null: false
      add :lot_id, :integer
      add :amount_cents, :integer, null: false
      add :occurred_on, :date

      timestamps(type: :utc_datetime_usec)
    end

    create index(:deposit_dispositions, [:group_id, :kind])
    create index(:deposit_dispositions, [:payment_operation_id])
    create index(:deposit_dispositions, [:lot_id])

    # Per-lot claim of one payment to the issued value of the lot its
    # converted cash helped fund; the claim is revoked by a chargeback.
    create table(:lot_entitlements) do
      add :lot_id, references(:credit_lots), null: false
      add :payment_operation_id, :string
      add :entitled_cents, :integer, null: false
      add :removed_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:lot_entitlements, [:lot_id])
    create index(:lot_entitlements, [:payment_operation_id])

    alter table(:credit_lots) do
      # Entitlement that a chargeback could not take out of the lot because
      # the credit had already left it.
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end
  end
end
