defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :deposit_due_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    execute """
    UPDATE rooms
    SET status = CASE
      WHEN (SELECT status FROM groups WHERE groups.id = rooms.group_id) = 'active'
        THEN 'active'
      ELSE 'cancelled'
    END,
    deposit_due_cents = CASE
      WHEN (SELECT rate_plan FROM groups WHERE groups.id = rooms.group_id) = 'advance_purchase'
        THEN CAST((julianday((SELECT departure_on FROM groups WHERE groups.id = rooms.group_id)) -
          julianday((SELECT arrival_on FROM groups WHERE groups.id = rooms.group_id))) * nightly_rate_cents AS INTEGER)
      ELSE CAST(((julianday((SELECT departure_on FROM groups WHERE groups.id = rooms.group_id)) -
          julianday((SELECT arrival_on FROM groups WHERE groups.id = rooms.group_id))) * nightly_rate_cents * 20 + 50) / 100 AS INTEGER)
    END
    """

    alter table(:credit_allocations) do
      add :room_id, references(:rooms, on_delete: :delete_all)
      add :funding_operation_id, :string
    end

    create index(:credit_allocations, [:room_id])
    create index(:credit_allocations, [:funding_operation_id])

    create table(:cash_allocations) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :room_id, references(:rooms, on_delete: :delete_all), null: false
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
    end

    create index(:cash_allocations, [:group_id, :room_id])
    create index(:cash_allocations, [:payment_operation_id])

    create table(:payment_accountings) do
      add :payment_operation_id, :string, null: false
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :recorded_cents, :integer, null: false
      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
    end

    create unique_index(:payment_accountings, [:payment_operation_id])
    create index(:payment_accountings, [:group_id])

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:credit_lot_contributions) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :payment_operation_id, :string
      add :principal_cents, :integer, null: false
      add :entitlement_cents, :integer, null: false
    end

    create index(:credit_lot_contributions, [:payment_operation_id])
    create index(:credit_lot_contributions, [:credit_lot_id])
  end

  def down do
    drop table(:credit_lot_contributions)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    drop table(:payment_accountings)
    drop table(:cash_allocations)

    alter table(:credit_allocations) do
      remove :funding_operation_id
      remove :room_id
    end

    alter table(:rooms) do
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :deposit_due_cents
      remove :status
    end
  end
end
