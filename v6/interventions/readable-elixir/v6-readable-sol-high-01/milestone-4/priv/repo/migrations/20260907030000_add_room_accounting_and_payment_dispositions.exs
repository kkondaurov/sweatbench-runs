defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentDispositions do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    alter table(:credit_allocations) do
      add :room_record_id, references(:rooms, type: :binary_id, on_delete: :delete_all)
      add :funding_operation_id, :string
      add :funding_order, :integer
    end

    create index(:credit_allocations, [:room_record_id])
    create index(:credit_allocations, [:funding_operation_id])

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:cash_payments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :payment_operation_id, :string, null: false

      add :group_record_id, references(:groups, type: :binary_id, on_delete: :delete_all),
        null: false

      add :funding_order, :integer, null: false
      add :recorded_cents, :integer, null: false
      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cash_payments, [:payment_operation_id])
    create index(:cash_payments, [:group_record_id, :funding_order])

    create table(:cash_allocations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :group_record_id, references(:groups, type: :binary_id, on_delete: :delete_all),
        null: false

      add :room_record_id, references(:rooms, type: :binary_id, on_delete: :delete_all),
        null: false

      add :cash_payment_id,
          references(:cash_payments, type: :binary_id, on_delete: :delete_all)

      add :funding_order, :integer, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:cash_allocations, [:group_record_id, :funding_order])
    create index(:cash_allocations, [:room_record_id])
    create index(:cash_allocations, [:cash_payment_id])

    create table(:credit_entitlements, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all),
        null: false

      add :cash_payment_id,
          references(:cash_payments, type: :binary_id, on_delete: :delete_all),
          null: false

      add :principal_cents, :integer, null: false
      add :credit_cents, :integer, null: false
      add :revoked_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:credit_entitlements, [:cash_payment_id])
    create unique_index(:credit_entitlements, [:credit_lot_id, :cash_payment_id])

    flush()
    GroupStay.RoomAccountingBackfill.run(repo())
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:cash_allocations)
    drop table(:cash_payments)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    drop index(:credit_allocations, [:funding_operation_id])
    drop index(:credit_allocations, [:room_record_id])

    alter table(:credit_allocations) do
      remove :funding_order
      remove :funding_operation_id
      remove :room_record_id
    end

    alter table(:rooms) do
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :deposit_due_cents
      remove :lodging_total_cents
      remove :status
    end
  end
end
