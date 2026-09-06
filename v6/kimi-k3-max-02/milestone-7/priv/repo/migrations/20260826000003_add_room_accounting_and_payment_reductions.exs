defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :cash_converted_cents, :integer, null: false, default: 0
    end

    # Backfill the room-level lodging and deposit amounts already used to
    # calculate each group's requirement: nights times the nightly rate, and a
    # 20% deposit (rounded half-up per room) for flexible rooms or the full
    # lodging amount for advance-purchase rooms.
    execute(
      """
      UPDATE rooms SET
        lodging_total_cents = nightly_rate_cents * CAST(julianday(
          (SELECT departure_on FROM groups WHERE groups.id = rooms.group_id)
        ) - julianday(
          (SELECT arrival_on FROM groups WHERE groups.id = rooms.group_id)
        ) AS INTEGER),
        deposit_due_cents = CASE
          WHEN (SELECT rate_plan FROM groups WHERE groups.id = rooms.group_id) = 'advance_purchase'
            THEN nightly_rate_cents * CAST(julianday(
              (SELECT departure_on FROM groups WHERE groups.id = rooms.group_id)
            ) - julianday(
              (SELECT arrival_on FROM groups WHERE groups.id = rooms.group_id)
            ) AS INTEGER)
          ELSE (nightly_rate_cents * CAST(julianday(
              (SELECT departure_on FROM groups WHERE groups.id = rooms.group_id)
            ) - julianday(
              (SELECT arrival_on FROM groups WHERE groups.id = rooms.group_id)
            ) AS INTEGER) * 20 + 50) / 100
        END
      """,
      "SELECT 1"
    )

    alter table(:groups) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:credit_applications) do
      add :operation_id, :string
    end

    # One funding source per cash amount applied to a group: a durably
    # recorded cash payment, or the unattributed senior block that brings
    # pre-durable funding forward. The disposition columns partition
    # amount_cents exactly. The integer primary key preserves seniority: the
    # legacy block is inserted first, then payments in commit order.
    create table(:cash_fundings) do
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :operation_id, :string
      add :amount_cents, :integer, null: false
      add :held_cents, :integer, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:cash_fundings, [:group_id])
    create unique_index(:cash_fundings, [:operation_id])

    create table(:room_fundings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :status, :string, null: false, default: "held"

      add :cash_funding_id, references(:cash_fundings, on_delete: :delete_all)

      add :credit_application_id,
          references(:credit_applications, type: :binary_id, on_delete: :delete_all)

      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:room_fundings, [:room_id])
    create index(:room_fundings, [:cash_funding_id])
    create index(:room_fundings, [:credit_application_id])

    # Each payment's share of a hotel-credit lot its cash was converted into,
    # assigned in funding order so a chargeback can revoke exactly that share.
    create table(:credit_lot_entitlements, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all),
        null: false

      add :cash_funding_id, references(:cash_fundings, on_delete: :delete_all), null: false
      add :entitlement_cents, :integer, null: false
      add :revoked_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:credit_lot_entitlements, [:credit_lot_id])
    create unique_index(:credit_lot_entitlements, [:cash_funding_id, :credit_lot_id])

    flush()

    GroupStay.Groups.bring_forward_legacy_funding()
  end

  def down do
    drop table(:credit_lot_entitlements)
    drop table(:room_fundings)
    drop table(:cash_fundings)

    alter table(:credit_applications) do
      remove :operation_id
    end

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:groups) do
      remove :cash_reduced_cents
      remove :cash_charged_back_cents
    end

    alter table(:rooms) do
      remove :status
      remove :lodging_total_cents
      remove :deposit_due_cents
      remove :refunded_cents
      remove :retained_cents
      remove :cash_converted_cents
    end
  end
end
