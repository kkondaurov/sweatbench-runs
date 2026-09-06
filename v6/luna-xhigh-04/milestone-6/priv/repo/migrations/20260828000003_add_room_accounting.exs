defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :deposit_due_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    execute("""
    UPDATE rooms
    SET status = (SELECT status FROM groups WHERE groups.group_id = rooms.group_id),
        deposit_due_cents = CASE
          WHEN (SELECT rate_plan FROM groups WHERE groups.group_id = rooms.group_id) = 'advance_purchase'
            THEN CAST((julianday((SELECT departure_on FROM groups WHERE groups.group_id = rooms.group_id)) -
                       julianday((SELECT arrival_on FROM groups WHERE groups.group_id = rooms.group_id))) AS INTEGER)
                 * nightly_rate_cents
          ELSE CAST(((CAST((julianday((SELECT departure_on FROM groups WHERE groups.group_id = rooms.group_id)) -
                            julianday((SELECT arrival_on FROM groups WHERE groups.group_id = rooms.group_id))) AS INTEGER)
                      * nightly_rate_cents * 20) + 50) / 100 AS INTEGER)
        END
    """)

    alter table(:ledger) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
      add :credit_shortfall_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:credit_allocations) do
      add :room_id, :string
      add :funding_operation_id, :string
    end

    create table(:cash_payments, primary_key: false) do
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

    create index(:cash_payments, [:group_id])

    create table(:cash_allocations) do
      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :delete_all),
          null: false

      add :room_id, :string, null: false
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
      add :disposition, :string, null: false
    end

    create index(:cash_allocations, [:group_id, :room_id])
    create index(:cash_allocations, [:payment_operation_id, :disposition])

    create table(:credit_lot_contributions) do
      add :credit_lot_id,
          references(:credit_lots, on_delete: :delete_all),
          null: false

      add :payment_operation_id, :string
      add :entitlement_cents, :integer, null: false
      add :clawed_back_cents, :integer, null: false, default: 0
    end

    create index(:credit_lot_contributions, [:credit_lot_id])
    create index(:credit_lot_contributions, [:payment_operation_id])
  end

  def down do
    drop index(:credit_lot_contributions, [:payment_operation_id])
    drop index(:credit_lot_contributions, [:credit_lot_id])
    drop table(:credit_lot_contributions)

    drop index(:cash_allocations, [:payment_operation_id, :disposition])
    drop index(:cash_allocations, [:group_id, :room_id])
    drop table(:cash_allocations)

    drop index(:cash_payments, [:group_id])
    drop table(:cash_payments)

    alter table(:credit_allocations) do
      remove :funding_operation_id
      remove :room_id
    end

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:ledger) do
      remove :credit_shortfall_cents
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
