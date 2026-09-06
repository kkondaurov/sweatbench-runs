defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions do
  use Ecto.Migration

  def up do
    alter table(:group_reservations) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
      add :accounting_backfilled, :boolean, null: false, default: false
    end

    alter table(:group_rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:credit_allocations) do
      add :group_room_id, references(:group_rooms, on_delete: :delete_all)
      add :funding_operation_id, :string
    end

    create index(:credit_allocations, [:group_room_id])
    create index(:credit_allocations, [:funding_operation_id])

    create table(:cash_payments) do
      add :operation_id, :string, null: false

      add :group_reservation_id, references(:group_reservations, on_delete: :restrict),
        null: false

      add :recorded_cents, :integer, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:cash_payments, [:operation_id])
    create index(:cash_payments, [:group_reservation_id])

    create table(:cash_allocations) do
      add :cash_payment_id, references(:cash_payments, on_delete: :delete_all), null: false
      add :group_room_id, references(:group_rooms, on_delete: :delete_all), null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:cash_allocations, [:cash_payment_id])
    create index(:cash_allocations, [:group_room_id])

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :cash_payment_id, references(:cash_payments, on_delete: :delete_all), null: false
      add :amount_cents, :integer, null: false
      add :revoked_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:credit_entitlements, [:credit_lot_id, :cash_payment_id])
    create index(:credit_entitlements, [:cash_payment_id])

    execute("""
    UPDATE group_rooms
    SET status = (SELECT status FROM group_reservations WHERE id = group_reservation_id),
        lodging_total_cents = nightly_rate_cents * CAST(
          julianday((SELECT departure_on FROM group_reservations WHERE id = group_reservation_id)) -
          julianday((SELECT arrival_on FROM group_reservations WHERE id = group_reservation_id)) AS INTEGER
        ),
        deposit_due_cents = CASE
          WHEN (SELECT rate_plan FROM group_reservations WHERE id = group_reservation_id) = 'flexible'
          THEN CAST((nightly_rate_cents * CAST(
            julianday((SELECT departure_on FROM group_reservations WHERE id = group_reservation_id)) -
            julianday((SELECT arrival_on FROM group_reservations WHERE id = group_reservation_id)) AS INTEGER
          ) * 20 + 50) / 100 AS INTEGER)
          ELSE nightly_rate_cents * CAST(
            julianday((SELECT departure_on FROM group_reservations WHERE id = group_reservation_id)) -
            julianday((SELECT arrival_on FROM group_reservations WHERE id = group_reservation_id)) AS INTEGER
          )
    END
    """)

    flush()
    GroupStay.Reservations.backfill_accounting!()
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:cash_allocations)
    drop table(:cash_payments)

    drop index(:credit_allocations, [:funding_operation_id])
    drop index(:credit_allocations, [:group_room_id])

    alter table(:credit_allocations) do
      remove :group_room_id
      remove :funding_operation_id
    end

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:group_rooms) do
      remove :status
      remove :lodging_total_cents
      remove :deposit_due_cents
    end

    alter table(:group_reservations) do
      remove :cash_reduced_cents
      remove :cash_charged_back_cents
      remove :accounting_backfilled
    end
  end
end
