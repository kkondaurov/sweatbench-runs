defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :text, null: false, default: "active"
      # Null for rooms that predate this release; computed and persisted when
      # the group's funding is brought forward.
      add :deposit_due_cents, :integer
    end

    alter table(:groups) do
      # False while the group still holds funding that predates this release;
      # flips to true once that funding has been brought forward as room
      # allocations.
      add :allocations_ready, :boolean, null: false, default: false
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:credit_applications) do
      # Null for applications that predate this release.
      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all)
      add :source_operation_id, :text
    end

    # Cash held on a room, attributed to the durable payment operation that
    # supplied it. The autoincrementing id preserves fill order; a null
    # payment_operation_id marks the unattributed senior block.
    create table(:room_cash_allocations, primary_key: false) do
      add :id, :integer, primary_key: true, autoincrement: true
      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all), null: false
      add :payment_operation_id, :text
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:room_cash_allocations, [:room_id])
    create index(:room_cash_allocations, [:payment_operation_id])

    # Current disposition of every durably recorded, applied cash payment.
    create table(:payment_records, primary_key: false) do
      add :id, :integer, primary_key: true, autoincrement: true
      add :operation_id, :text, null: false
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :amount_cents, :integer, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:payment_records, [:operation_id])
    create index(:payment_records, [:group_id])

    # The hotel-credit entitlement a payment holds in a lot issued when its
    # cash was converted. A null payment_operation_id is the unattributed
    # senior block's entitlement.
    create table(:credit_entitlements, primary_key: false) do
      add :id, :integer, primary_key: true, autoincrement: true

      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all),
        null: false

      add :payment_operation_id, :text
      add :entitlement_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_entitlements, [:credit_lot_id])
    create index(:credit_entitlements, [:payment_operation_id])
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:payment_records)
    drop table(:room_cash_allocations)

    alter table(:credit_applications) do
      remove :source_operation_id
      remove :room_id
    end

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:groups) do
      remove :allocations_ready
    end

    alter table(:rooms) do
      remove :deposit_due_cents
      remove :status
    end
  end
end
