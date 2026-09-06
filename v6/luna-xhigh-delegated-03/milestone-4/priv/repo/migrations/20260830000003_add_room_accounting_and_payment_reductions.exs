defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions do
  use Ecto.Migration

  def up do
    alter table(:group_rooms) do
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :status, :string, null: false, default: "active"
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    execute """
    UPDATE group_rooms
    SET lodging_total_cents =
          (julianday((SELECT departure_on FROM groups WHERE groups.group_id = group_rooms.group_id)) -
           julianday((SELECT arrival_on FROM groups WHERE groups.group_id = group_rooms.group_id))) * nightly_rate_cents,
        deposit_due_cents = CASE
          WHEN (SELECT rate_plan FROM groups WHERE groups.group_id = group_rooms.group_id) = 'advance_purchase'
            THEN (julianday((SELECT departure_on FROM groups WHERE groups.group_id = group_rooms.group_id)) -
                  julianday((SELECT arrival_on FROM groups WHERE groups.group_id = group_rooms.group_id))) * nightly_rate_cents
          ELSE CAST(((julianday((SELECT departure_on FROM groups WHERE groups.group_id = group_rooms.group_id)) -
                      julianday((SELECT arrival_on FROM groups WHERE groups.group_id = group_rooms.group_id))) *
                     nightly_rate_cents * 20 + 50) / 100 AS INTEGER)
        END
    """

    execute """
    UPDATE group_rooms
    SET status = (SELECT status FROM groups WHERE groups.group_id = group_rooms.group_id)
    """

    alter table(:credit_allocations) do
      add :room_id, :string
      add :source_operation_id, :string
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:cash_allocations) do
      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :delete_all),
          null: false

      add :room_id, :string, null: false
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
    end

    create index(:cash_allocations, [:group_id, :room_id])
    create index(:cash_allocations, [:payment_operation_id])

    create table(:payment_dispositions, primary_key: false) do
      add :payment_operation_id, :string, primary_key: true
      add :original_group_id, :string, null: false
      add :recorded_cents, :integer, null: false
      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
      add :charged_back, :boolean, null: false, default: false
    end

    create table(:credit_lot_contributions) do
      add :credit_lot_id,
          references(:credit_lots, column: :id, on_delete: :delete_all),
          null: false

      add :payment_operation_id, :string
      add :entitlement_cents, :integer, null: false
    end

    create index(:credit_lot_contributions, [:credit_lot_id])
    create index(:credit_lot_contributions, [:payment_operation_id])
  end

  def down do
    drop table(:credit_lot_contributions)
    drop table(:payment_dispositions)
    drop table(:cash_allocations)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:credit_allocations) do
      remove :source_operation_id
      remove :room_id
    end

    alter table(:group_rooms) do
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :status
      remove :deposit_due_cents
      remove :lodging_total_cents
    end
  end
end
