defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :accounting_version, :integer, null: false, default: 0
    end

    alter table(:group_rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    alter table(:hotel_credit_allocations) do
      add :room_id, :string
      add :source_operation_id, :string
    end

    alter table(:hotel_credit_lots) do
      add :issued_cents, :integer, null: false, default: 0
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:ledger_totals) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
      add :credit_shortfall_cents, :integer, null: false, default: 0
    end

    create table(:cash_payment_allocations) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :room_id, :string, null: false
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:cash_payment_allocations, [:group_id, :room_id])
    create index(:cash_payment_allocations, [:payment_operation_id])

    create table(:cash_payment_states) do
      add :payment_operation_id, :string, null: false
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :recorded_cents, :integer, null: false
      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:cash_payment_states, [:payment_operation_id])
    create index(:cash_payment_states, [:group_id])

    create table(:credit_entitlements) do
      add :lot_id, references(:hotel_credit_lots, on_delete: :delete_all), null: false
      add :payment_operation_id, :string
      add :entitlement_cents, :integer, null: false
      add :revoked_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:credit_entitlements, [:lot_id])
    create index(:credit_entitlements, [:payment_operation_id])

    # Materialize pre-release funding while the schema change is still one
    # migration transaction. Reads and rejected operations must not need to
    # perform this work later.
    flush()
    GroupStay.Operations.backfill_legacy_room_accounting!()
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:cash_payment_states)
    drop table(:cash_payment_allocations)

    alter table(:ledger_totals) do
      remove :credit_shortfall_cents
      remove :cash_charged_back_cents
      remove :cash_reduced_cents
    end

    alter table(:hotel_credit_lots) do
      remove :unrecovered_clawback_cents
      remove :issued_cents
    end

    alter table(:hotel_credit_allocations) do
      remove :source_operation_id
      remove :room_id
    end

    alter table(:group_rooms) do
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :deposit_due_cents
      remove :lodging_cents
      remove :status
    end

    alter table(:groups) do
      remove :accounting_version
    end
  end
end
