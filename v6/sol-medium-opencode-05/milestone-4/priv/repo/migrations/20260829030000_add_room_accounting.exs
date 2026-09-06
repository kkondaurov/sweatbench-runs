defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :accounting_initialized, :boolean, null: false, default: false
    end

    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer
      add :deposit_due_cents, :integer
    end

    execute("""
    UPDATE rooms
    SET status = (SELECT status FROM groups WHERE groups.id = rooms.group_ref),
        lodging_total_cents = nightly_rate_cents * CAST(
          julianday((SELECT departure_on FROM groups WHERE groups.id = rooms.group_ref)) -
          julianday((SELECT arrival_on FROM groups WHERE groups.id = rooms.group_ref)) AS INTEGER
        )
    """)

    execute("""
    UPDATE rooms
    SET deposit_due_cents = CASE
      WHEN (SELECT rate_plan FROM groups WHERE groups.id = rooms.group_ref) = 'flexible'
        THEN CAST(lodging_total_cents / 5 AS INTEGER) +
          CASE WHEN lodging_total_cents % 5 >= 3 THEN 1 ELSE 0 END
      ELSE lodging_total_cents
    END
    """)

    create table(:fundings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_ref, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :operation_id, :string
      add :kind, :string, null: false
      add :lot_id, references(:credit_lots, type: :binary_id, on_delete: :restrict)
      add :funding_order, :integer, null: false
      add :original_amount_cents, :integer, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:fundings, [:group_ref, :funding_order])
    create index(:fundings, [:operation_id])
    create index(:fundings, [:lot_id])

    create table(:room_allocations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all), null: false

      add :funding_id, references(:fundings, type: :binary_id, on_delete: :delete_all),
        null: false

      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:room_allocations, [:room_id, :funding_id])
    create index(:room_allocations, [:funding_id])

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:credit_entitlements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all), null: false

      add :funding_id, references(:fundings, type: :binary_id, on_delete: :delete_all),
        null: false

      add :principal_cents, :integer, null: false
      add :entitlement_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:credit_entitlements, [:lot_id, :funding_id])
    create index(:credit_entitlements, [:funding_id])
  end

  def down do
    drop table(:credit_entitlements)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    drop table(:room_allocations)
    drop table(:fundings)

    alter table(:rooms) do
      remove :status
      remove :lodging_total_cents
      remove :deposit_due_cents
    end

    alter table(:groups) do
      remove :accounting_initialized
    end
  end
end
