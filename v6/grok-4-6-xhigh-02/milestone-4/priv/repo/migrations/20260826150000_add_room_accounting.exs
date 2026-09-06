defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def change do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :deposit_due_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    alter table(:groups) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:room_allocations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
      add :source_operation_id, :string
      add :fill_seq, :integer, null: false

      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all), null: false

      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :restrict)

      timestamps(type: :utc_datetime)
    end

    create index(:room_allocations, [:room_id])
    create index(:room_allocations, [:source_operation_id])
    create index(:room_allocations, [:credit_lot_id])
    create index(:room_allocations, [:fill_seq])

    create table(:cash_payments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :operation_id, :string, null: false
      add :group_id, :string, null: false
      add :recorded_cents, :integer, null: false
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

    create table(:credit_entitlements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :payment_operation_id, :string
      add :cash_cents, :integer, null: false
      add :entitlement_cents, :integer, null: false
      add :position, :integer, null: false

      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_entitlements, [:credit_lot_id])
    create index(:credit_entitlements, [:payment_operation_id])

    flush()

    GroupStay.Accounting.Backfill.run()
  end
end
