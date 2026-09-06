defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
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

    alter table(:credit_applications) do
      add :room_id, references(:rooms, on_delete: :delete_all)
      add :operation_id, :string
      add :status, :string, null: false, default: "active"
      add :position, :integer
    end

    create index(:credit_applications, [:room_id])
    create index(:credit_applications, [:operation_id])
    create index(:credit_applications, [:status])

    execute("""
    UPDATE credit_applications
    SET status = 'settled'
    WHERE group_id IN (SELECT id FROM groups WHERE status = 'cancelled')
    """)

    create table(:payment_fundings) do
      add :partner_operation_id, references(:partner_operations, on_delete: :restrict),
        null: false

      add :group_id, references(:groups, on_delete: :restrict), null: false
      add :recorded_cents, :integer, null: false
      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:payment_fundings, [:partner_operation_id])
    create index(:payment_fundings, [:group_id])

    create table(:cash_allocations) do
      add :room_id, references(:rooms, on_delete: :delete_all), null: false
      add :payment_funding_id, references(:payment_fundings, on_delete: :restrict)
      add :amount_cents, :integer, null: false
      add :position, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:cash_allocations, [:room_id])
    create index(:cash_allocations, [:payment_funding_id])
    create unique_index(:cash_allocations, [:payment_funding_id, :position])

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :payment_funding_id, references(:payment_fundings, on_delete: :restrict)
      add :principal_cents, :integer, null: false
      add :entitlement_cents, :integer, null: false
      add :revoked_cents, :integer, null: false, default: 0
      add :position, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_entitlements, [:credit_lot_id, :position])
    create index(:credit_entitlements, [:payment_funding_id])

    execute("""
    UPDATE rooms
    SET status = COALESCE((SELECT groups.status FROM groups WHERE groups.id = rooms.group_id), 'active'),
        lodging_total_cents = nightly_rate_cents * CAST(
          julianday((SELECT departure_on FROM groups WHERE groups.id = rooms.group_id)) -
          julianday((SELECT arrival_on FROM groups WHERE groups.id = rooms.group_id)) AS INTEGER
        )
    """)

    execute("""
    UPDATE rooms
    SET deposit_due_cents = CASE
      WHEN (SELECT rate_plan FROM groups WHERE groups.id = rooms.group_id) = 'flexible'
        THEN CAST((lodging_total_cents + 2) / 5 AS INTEGER)
      ELSE lodging_total_cents
    END
    """)

    # Earlier releases stored funding only at group level. Preserve its senior, cash-first
    # room allocation here; durable-operation attribution is reconstructed by the application.
    execute("""
    UPDATE rooms
    SET cash_paid_cents = MIN(
          deposit_due_cents,
          MAX(0, (SELECT cash_paid_cents FROM groups WHERE groups.id = rooms.group_id) -
            COALESCE((SELECT SUM(prior.deposit_due_cents) FROM rooms prior
                      WHERE prior.group_id = rooms.group_id AND prior.position < rooms.position), 0))
        )
    """)

    execute("""
    UPDATE rooms
    SET credit_paid_cents = MIN(
          deposit_due_cents - cash_paid_cents,
          MAX(0, (SELECT credit_paid_cents FROM groups WHERE groups.id = rooms.group_id) -
            COALESCE((SELECT SUM(prior.deposit_due_cents - prior.cash_paid_cents) FROM rooms prior
                      WHERE prior.group_id = rooms.group_id AND prior.position < rooms.position), 0))
        )
    """)

    execute("""
    INSERT INTO cash_allocations (room_id, payment_funding_id, amount_cents, position, inserted_at, updated_at)
    SELECT rooms.id, NULL, rooms.cash_paid_cents, rooms.position, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM rooms
    JOIN groups ON groups.id = rooms.group_id
    WHERE groups.status = 'active' AND rooms.cash_paid_cents > 0
    """)

    flush()
    GroupStay.Operations.backfill_room_accounting!()

    execute("""
    UPDATE rooms
    SET cash_paid_cents = 0,
        credit_paid_cents = 0
    WHERE status = 'cancelled'
    """)

    execute("""
    UPDATE groups
    SET lodging_total_cents = 0,
        deposit_due_cents = 0,
        deposit_paid_cents = 0,
        cash_paid_cents = 0,
        credit_paid_cents = 0
    WHERE status = 'cancelled'
    """)
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:cash_allocations)
    drop table(:payment_fundings)

    alter table(:credit_applications) do
      remove :room_id
      remove :operation_id
      remove :status
      remove :position
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
      remove :cash_paid_cents
      remove :credit_paid_cents
    end
  end
end
