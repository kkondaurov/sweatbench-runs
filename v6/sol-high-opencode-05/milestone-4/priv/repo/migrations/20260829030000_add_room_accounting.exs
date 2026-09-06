defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :accounting_initialized, :boolean, null: false, default: false
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
    end

    execute("""
    UPDATE rooms
    SET status = (SELECT status FROM groups WHERE groups.id = rooms.group_record_id),
        lodging_cents = nightly_rate_cents * CAST(
          julianday((SELECT departure_on FROM groups WHERE groups.id = rooms.group_record_id)) -
          julianday((SELECT arrival_on FROM groups WHERE groups.id = rooms.group_record_id)) AS INTEGER
        )
    """)

    execute("""
    UPDATE rooms
    SET deposit_due_cents = CASE
      WHEN (SELECT rate_plan FROM groups WHERE groups.id = rooms.group_record_id) = 'flexible'
        THEN CAST(lodging_cents / 5 AS INTEGER) + CASE WHEN lodging_cents % 5 >= 3 THEN 1 ELSE 0 END
      ELSE lodging_cents
    END
    """)

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:cash_payments, primary_key: false) do
      add :payment_operation_id, :string, primary_key: true

      add :group_record_id, references(:groups, type: :binary_id, on_delete: :delete_all),
        null: false

      add :recorded_cents, :integer, null: false
      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
    end

    create index(:cash_payments, [:group_record_id])

    create table(:room_funding_allocations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :group_record_id, references(:groups, type: :binary_id, on_delete: :delete_all),
        null: false

      add :room_record_id, references(:rooms, type: :binary_id, on_delete: :delete_all),
        null: false

      add :kind, :string, null: false
      add :source_operation_id, :string
      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :restrict)
      add :allocation_order, :integer, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:room_funding_allocations, [:group_record_id, :allocation_order])
    create index(:room_funding_allocations, [:room_record_id])
    create index(:room_funding_allocations, [:source_operation_id])
    create index(:room_funding_allocations, [:credit_lot_id])

    create table(:credit_entitlements, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all),
        null: false

      add :payment_operation_id, :string, null: false
      add :principal_cents, :integer, null: false
      add :entitlement_cents, :integer, null: false
      add :revoked, :boolean, null: false, default: false
    end

    create index(:credit_entitlements, [:payment_operation_id])
    create index(:credit_entitlements, [:credit_lot_id])
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:room_funding_allocations)
    drop table(:cash_payments)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:rooms) do
      remove :deposit_due_cents
      remove :lodging_cents
      remove :status
    end

    alter table(:groups) do
      remove :cash_charged_back_cents
      remove :cash_reduced_cents
      remove :accounting_initialized
    end
  end
end
