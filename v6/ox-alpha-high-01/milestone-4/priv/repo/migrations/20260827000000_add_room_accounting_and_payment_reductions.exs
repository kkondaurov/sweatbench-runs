defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions do
  use Ecto.Migration

  def up do
    create table(:allocations, primary_key: false) do
      # The integer primary key is SQLite's rowid alias, so rows are ordered by
      # fill order; removals walk a payment's allocations in reverse.
      add :id, :integer, primary_key: true
      add :group_id, references(:groups, type: :binary_id), null: false
      add :room_id, :string, null: false
      add :kind, :string, null: false
      add :position, :integer, null: false
      add :amount_cents, :integer, null: false
      add :payment_operation_id, :string
      add :credit_lot_id, references(:credit_lots, type: :binary_id)

      timestamps(type: :utc_datetime)
    end

    create index(:allocations, [:group_id])
    create index(:allocations, [:payment_operation_id])

    create table(:cash_payments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :operation_id, :string, null: false
      add :group_id, references(:groups, type: :binary_id), null: false
      add :amount_cents, :integer, null: false
      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cash_payments, [:operation_id])
    create index(:cash_payments, [:group_id])

    create table(:lot_entitlements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :credit_lot_id, references(:credit_lots, type: :binary_id), null: false
      add :payment_operation_id, :string, null: false
      add :principal_cents, :integer, null: false
      add :entitled_cents, :integer, null: false
      add :unrecovered_clawback_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:lot_entitlements, [:credit_lot_id])
    create index(:lot_entitlements, [:payment_operation_id])

    # Bring pre-existing funding forward as room allocations and per-payment
    # dispositions without changing any aggregate balance.
    flush()
    GroupStay.Groups.Backfill.run()
  end

  def down do
    drop table(:lot_entitlements)
    drop table(:cash_payments)
    drop table(:allocations)
  end
end
