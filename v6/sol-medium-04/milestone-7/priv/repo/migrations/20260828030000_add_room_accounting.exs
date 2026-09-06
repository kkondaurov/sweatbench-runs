defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
    end

    execute """
    UPDATE rooms
    SET lodging_total_cents = nightly_rate_cents * CAST(
          julianday((SELECT departure_on FROM groups WHERE groups.id = rooms.group_id)) -
          julianday((SELECT arrival_on FROM groups WHERE groups.id = rooms.group_id)) AS INTEGER
        ),
        deposit_due_cents = CASE
          WHEN (SELECT rate_plan FROM groups WHERE groups.id = rooms.group_id) = 'flexible'
          THEN CAST((nightly_rate_cents * CAST(
            julianday((SELECT departure_on FROM groups WHERE groups.id = rooms.group_id)) -
            julianday((SELECT arrival_on FROM groups WHERE groups.id = rooms.group_id)) AS INTEGER
          ) * 20 + 50) / 100 AS INTEGER)
          ELSE nightly_rate_cents * CAST(
            julianday((SELECT departure_on FROM groups WHERE groups.id = rooms.group_id)) -
            julianday((SELECT arrival_on FROM groups WHERE groups.id = rooms.group_id)) AS INTEGER
          )
        END
    """

    execute """
    UPDATE rooms
    SET status = 'cancelled'
    WHERE group_id IN (SELECT id FROM groups WHERE status = 'cancelled')
    """

    execute """
    UPDATE groups
    SET lodging_total_cents = 0,
        deposit_due_cents = 0,
        deposit_paid_cents = 0,
        cash_paid_cents = 0,
        credit_paid_cents = 0
    WHERE status = 'cancelled'
    """

    alter table(:credit_applications) do
      add :room_id, references(:rooms, on_delete: :delete_all)
      add :funding_operation_id, :string
    end

    create table(:payment_accounts) do
      add :operation_record_id, references(:operation_records, on_delete: :restrict)
      add :operation_id, :string, null: false
      add :group_id, references(:groups, type: :string, on_delete: :restrict), null: false
      add :recorded_cents, :integer, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:payment_accounts, [:operation_id])
    create unique_index(:payment_accounts, [:operation_record_id])
    create index(:payment_accounts, [:group_id])

    create table(:cash_allocations) do
      add :group_id, references(:groups, type: :string, on_delete: :delete_all), null: false
      add :room_id, references(:rooms, on_delete: :delete_all), null: false
      add :payment_account_id, references(:payment_accounts, on_delete: :restrict)
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:cash_allocations, [:group_id, :room_id])
    create index(:cash_allocations, [:payment_account_id])

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :payment_account_id, references(:payment_accounts, on_delete: :restrict), null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:credit_entitlements, [:credit_lot_id, :payment_account_id])
    create index(:credit_entitlements, [:payment_account_id])
  end

  def down do
    drop table(:credit_entitlements)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    drop table(:cash_allocations)
    drop table(:payment_accounts)

    alter table(:credit_applications) do
      remove :funding_operation_id
      remove :room_id
    end

    alter table(:rooms) do
      remove :deposit_due_cents
      remove :lodging_total_cents
      remove :status
    end
  end
end
