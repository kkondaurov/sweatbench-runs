defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:credit_allocations) do
      add :room_id, references(:rooms, on_delete: :restrict)
      add :funding_operation_id, :string
      # Release 05 establishes the cross-kind order after this migration's
      # reconstruction has run. Keeping the column here makes a fresh database
      # compatible with the current runtime schemas throughout that backfill.
      add :allocation_order, :integer, null: false, default: 0
    end

    create index(:credit_allocations, [:room_id])
    create index(:credit_allocations, [:funding_operation_id])

    create table(:cash_fundings) do
      add :group_id,
          references(:groups,
            column: :group_id,
            type: :string,
            on_delete: :restrict
          ),
          null: false

      # NULL identifies the one unattributed funding block reconstructed for a
      # group that predates durable operation receipts.
      add :payment_operation_id, :string
      add :funding_order, :integer, null: false
      add :recorded_cents, :integer, null: false
      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
      add :participated_in_transfer, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cash_fundings, [:payment_operation_id])
    create index(:cash_fundings, [:group_id, :funding_order])

    create table(:cash_allocations) do
      add :cash_funding_id, references(:cash_fundings, on_delete: :restrict), null: false
      add :room_id, references(:rooms, on_delete: :restrict), null: false
      add :amount_cents, :integer, null: false
      add :allocation_order, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:cash_allocations, [:cash_funding_id])
    create index(:cash_allocations, [:room_id])

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots, on_delete: :restrict), null: false
      add :cash_funding_id, references(:cash_fundings, on_delete: :restrict), null: false
      add :principal_cents, :integer, null: false
      add :entitlement_cents, :integer, null: false
      add :revoked, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_entitlements, [:cash_funding_id])
    create index(:credit_entitlements, [:credit_lot_id])

    flush()

    execute("""
    UPDATE rooms
    SET status = CASE
          WHEN (SELECT status FROM groups WHERE groups.group_id = rooms.group_id) = 'cancelled'
            THEN 'cancelled'
          ELSE 'active'
        END,
        lodging_total_cents = nightly_rate_cents * CAST(
          julianday((SELECT departure_on FROM groups WHERE groups.group_id = rooms.group_id)) -
          julianday((SELECT arrival_on FROM groups WHERE groups.group_id = rooms.group_id)) AS INTEGER
        ),
        deposit_due_cents = CASE
          WHEN (SELECT rate_plan FROM groups WHERE groups.group_id = rooms.group_id) = 'advance_purchase'
            THEN nightly_rate_cents * CAST(
              julianday((SELECT departure_on FROM groups WHERE groups.group_id = rooms.group_id)) -
              julianday((SELECT arrival_on FROM groups WHERE groups.group_id = rooms.group_id)) AS INTEGER
            )
          ELSE CAST((nightly_rate_cents * CAST(
              julianday((SELECT departure_on FROM groups WHERE groups.group_id = rooms.group_id)) -
              julianday((SELECT arrival_on FROM groups WHERE groups.group_id = rooms.group_id)) AS INTEGER
            ) * 20 + 50) / 100 AS INTEGER)
        END
    """)

    # This procedural backfill reconstructs the interleaving between legacy
    # funding and durable cash/credit operations. It deliberately changes only
    # allocation and classification records, never an aggregate balance.
    execute(fn -> GroupStay.Reservations.AccountingBackfill.run(repo()) end)
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:cash_allocations)
    drop table(:cash_fundings)

    drop index(:credit_allocations, [:funding_operation_id])
    drop index(:credit_allocations, [:room_id])

    alter table(:credit_allocations) do
      remove :funding_operation_id
      remove :room_id
    end

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
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
