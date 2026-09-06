defmodule GroupStay.Repo.Migrations.AddCancellationEconomics do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :policy_version, :text, null: false, default: "flex-14"
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
      add :cash_converted_to_credit_cents, :integer, null: false, default: 0
    end

    execute("""
    UPDATE groups
    SET policy_version = CASE
      WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
      WHEN booked_on >= '2027-01-01' THEN 'flex-30'
      ELSE 'flex-14'
    END,
    cash_paid_cents = deposit_paid_cents,
    credit_paid_cents = 0,
    cash_converted_to_credit_cents = 0
    """)

    create table(:credit_lots) do
      add :guest_id, :text, null: false
      add :source_operation_id, :text, null: false
      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false
    end

    create index(:credit_lots, [:guest_id, :expires_on, :source_operation_id])

    create table(:group_credit_allocations) do
      add :group_record_id, references(:groups, on_delete: :delete_all), null: false
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :amount_cents, :integer, null: false
    end

    create index(:group_credit_allocations, [:group_record_id])
    create index(:group_credit_allocations, [:credit_lot_id])
  end

  def down do
    drop table(:group_credit_allocations)
    drop table(:credit_lots)

    alter table(:groups) do
      remove :cash_converted_to_credit_cents
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :policy_version
    end
  end
end
