defmodule GroupStay.Repo.Migrations.RoomAccountingAndPaymentReductions do
  use Ecto.Migration

  alias GroupStay.Deposits.LegacyBackfill

  # The backfill reads and writes through the repo, whose pool connections can
  # only see this migration's DDL once it is committed.
  @disable_ddl_transaction true

  def up do
    alter table(:group_rooms) do
      add :status, :text, null: false, default: "active"
      add :lodging_amount_cents, :integer
      add :deposit_due_cents, :integer
    end

    execute("""
    UPDATE group_rooms SET lodging_amount_cents =
      CAST(julianday((SELECT departure_on FROM groups WHERE groups.id = group_rooms.group_id)) -
           julianday((SELECT arrival_on FROM groups WHERE groups.id = group_rooms.group_id))
           AS INTEGER) * nightly_rate_cents
    """)

    # Per-room deposits follow the same rules as opening: flexible rooms are
    # rounded separately with half-up rounding, advance-purchase rooms need
    # their full lodging amount.
    execute("""
    UPDATE group_rooms SET deposit_due_cents =
      CASE (SELECT rate_plan FROM groups WHERE groups.id = group_rooms.group_id)
        WHEN 'advance_purchase' THEN lodging_amount_cents
        ELSE (2 * lodging_amount_cents * 20 + 100) / 200
      END
    """)

    alter table(:groups) do
      remove :deposit_paid_cents
      remove :cash_paid_cents
      remove :credit_paid_cents
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:credit_applications) do
      add :room_id, references(:group_rooms, type: :uuid, on_delete: :delete_all)
      add :fill_seq, :integer
    end

    alter table(:ledger_entries) do
      add :operation_id, :text
    end

    create table(:cash_allocations, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :group_id, references(:groups, type: :uuid, on_delete: :delete_all), null: false
      add :room_id, references(:group_rooms, type: :uuid, on_delete: :delete_all), null: false
      add :operation_id, :text
      add :amount_cents, :integer, null: false
      add :fill_seq, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:cash_allocations, [:group_id])
    create index(:cash_allocations, [:room_id])
    create index(:cash_allocations, [:operation_id])

    create table(:credit_lot_contributions, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :credit_lot_id, references(:credit_lots, type: :uuid, on_delete: :delete_all),
        null: false

      add :operation_id, :text
      add :entitlement_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_lot_contributions, [:credit_lot_id])
    create index(:credit_lot_contributions, [:operation_id])

    create table(:payment_cash_dispositions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :operation_id, :text, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:payment_cash_dispositions, [:operation_id])

    # Push the buffered DDL to the database before the backfill's own repo
    # queries run.
    flush()

    backfill()
  end

  def down do
    drop table(:payment_cash_dispositions)
    drop table(:credit_lot_contributions)
    drop table(:cash_allocations)

    alter table(:ledger_entries) do
      remove :operation_id
    end

    alter table(:credit_applications) do
      remove :room_id
      remove :fill_seq
    end

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:groups) do
      add :deposit_paid_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    alter table(:group_rooms) do
      remove :deposit_due_cents
      remove :lodging_amount_cents
      remove :status
    end
  end

  # Materializes room allocations for funding that already exists without
  # changing any aggregate cash, credit, or liability balance. Funding that
  # predates durable operation records becomes one unattributed senior block
  # per active group, allocated before funding represented by durable records.
  defp backfill do
    LegacyBackfill.run()
  end
end
