defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :room_accounting_initialized, :boolean, null: false, default: false
    end

    alter table(:group_rooms) do
      add :lodging_amount_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :status, :string, null: false, default: "active"
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    execute """
    UPDATE group_rooms
    SET lodging_amount_cents = CAST(
          (julianday(groups.departure_on) - julianday(groups.arrival_on)) * group_rooms.nightly_rate_cents
          AS INTEGER
        ),
        deposit_due_cents = CASE
          WHEN groups.rate_plan = 'advance_purchase' THEN CAST(
            (julianday(groups.departure_on) - julianday(groups.arrival_on)) * group_rooms.nightly_rate_cents
            AS INTEGER
          )
          ELSE CAST((
            (julianday(groups.departure_on) - julianday(groups.arrival_on)) * group_rooms.nightly_rate_cents * 20 + 50
          ) / 100 AS INTEGER)
        END
    FROM groups
    WHERE groups.group_id = group_rooms.group_id
    """

    alter table(:hotel_credit_allocations) do
      add :room_id, :string
      add :operation_id, :string
      add :status, :string, null: false, default: "active"
    end

    alter table(:hotel_credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:cash_allocations) do
      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :delete_all),
          null: false

      add :room_id, :string, null: false
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
      add :disposition, :string, null: false, default: "held"
    end

    create index(:cash_allocations, [:group_id, :room_id])
    create index(:cash_allocations, [:payment_operation_id])
    create index(:cash_allocations, [:group_id, :disposition])

    create table(:hotel_credit_entitlements) do
      add :credit_lot_id,
          references(:hotel_credit_lots, column: :id, type: :integer, on_delete: :restrict),
          null: false

      add :payment_operation_id, :string
      add :cash_amount_cents, :integer, null: false
      add :credit_amount_cents, :integer, null: false
    end

    create index(:hotel_credit_entitlements, [:credit_lot_id])
    create index(:hotel_credit_entitlements, [:payment_operation_id])

    flush()
    GroupStay.backfill_room_accounting!()
  end

  def down do
    drop table(:hotel_credit_entitlements)
    drop table(:cash_allocations)

    alter table(:hotel_credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:hotel_credit_allocations) do
      remove :room_id
      remove :operation_id
      remove :status
    end

    alter table(:group_rooms) do
      remove :lodging_amount_cents
      remove :deposit_due_cents
      remove :status
      remove :cash_paid_cents
      remove :credit_paid_cents
    end

    alter table(:groups) do
      remove :room_accounting_initialized
    end
  end
end
