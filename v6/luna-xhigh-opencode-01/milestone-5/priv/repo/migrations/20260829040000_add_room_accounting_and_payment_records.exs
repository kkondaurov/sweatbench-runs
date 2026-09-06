defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentRecords do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
      add :room_accounting_initialized, :boolean, null: false, default: false
    end

    alter table(:rooms) do
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :status, :string, null: false, default: "active"
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    execute("""
    UPDATE rooms
    SET lodging_total_cents = nightly_rate_cents *
          CAST(julianday((SELECT departure_on FROM groups WHERE groups.group_id = rooms.group_id)) -
               julianday((SELECT arrival_on FROM groups WHERE groups.group_id = rooms.group_id)) AS INTEGER),
        deposit_due_cents = CASE
          WHEN (SELECT rate_plan FROM groups WHERE groups.group_id = rooms.group_id) = 'advance_purchase'
            THEN nightly_rate_cents *
              CAST(julianday((SELECT departure_on FROM groups WHERE groups.group_id = rooms.group_id)) -
                   julianday((SELECT arrival_on FROM groups WHERE groups.group_id = rooms.group_id)) AS INTEGER)
          ELSE (nightly_rate_cents *
              CAST(julianday((SELECT departure_on FROM groups WHERE groups.group_id = rooms.group_id)) -
                   julianday((SELECT arrival_on FROM groups WHERE groups.group_id = rooms.group_id)) AS INTEGER) * 20 + 50) / 100
        END
    """)

    alter table(:credit_allocations) do
      add :room_id, :string
      add :funding_operation_id, :string
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:cash_allocations) do
      add :payment_operation_id, :string
      add :group_id, :string, null: false
      add :room_id, :string, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:cash_allocations, [:payment_operation_id])
    create index(:cash_allocations, [:group_id, :room_id])

    create table(:payment_accountings, primary_key: false) do
      add :payment_operation_id, :string, primary_key: true
      add :group_id, :string, null: false
      add :recorded_cents, :integer, null: false
      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
    end

    create index(:payment_accountings, [:group_id])

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :payment_operation_id, :string, null: false
      add :amount_cents, :integer, null: false
      add :revoked_cents, :integer, null: false, default: 0
    end

    create index(:credit_entitlements, [:credit_lot_id])
    create index(:credit_entitlements, [:payment_operation_id])
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:payment_accountings)
    drop table(:cash_allocations)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:credit_allocations) do
      remove :room_id
      remove :funding_operation_id
    end

    alter table(:rooms) do
      remove :lodging_total_cents
      remove :deposit_due_cents
      remove :status
      remove :cash_paid_cents
      remove :credit_paid_cents
    end

    alter table(:groups) do
      remove :reduced_cents
      remove :charged_back_cents
      remove :room_accounting_initialized
    end
  end
end
