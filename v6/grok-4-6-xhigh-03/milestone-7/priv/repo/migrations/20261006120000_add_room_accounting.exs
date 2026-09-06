defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def change do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    alter table(:groups) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :issued_cents, :integer, null: false, default: 0
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:funding_allocations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :source_kind, :string, null: false
      add :source_operation_id, :string
      add :funding_kind, :string, null: false
      add :amount_cents, :integer, null: false
      add :fill_sequence, :integer, null: false
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all), null: false

      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:funding_allocations, [:group_id])
    create index(:funding_allocations, [:room_id])
    create index(:funding_allocations, [:source_operation_id])

    create table(:payment_statements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :payment_operation_id, :string, null: false
      add :group_id, :string, null: false
      add :recorded_cents, :integer, null: false
      add :held_cents, :integer, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:payment_statements, [:payment_operation_id])
    create index(:payment_statements, [:group_id])

    create table(:credit_entitlements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :payment_operation_id, :string
      add :entitlement_cents, :integer, null: false
      add :position, :integer, null: false

      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_entitlements, [:credit_lot_id])
    create index(:credit_entitlements, [:payment_operation_id])

    flush()
    execute(&__MODULE__.backfill/0, &__MODULE__.noop/0)
  end

  def backfill do
    GroupStay.Groups.backfill_room_accounting!()
  end

  def noop, do: :ok
end
