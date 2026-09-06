defmodule GroupStay.Repo.Migrations.AddCancellationEconomics do
  use Ecto.Migration

  def change do
    alter table(:ledger) do
      add :cash_converted_to_credit_cents, :integer, null: false, default: 0
    end

    alter table(:groups) do
      add :policy_version, :string
      add :refundable_until, :date
      add :cash_paid_cents, :integer
      add :credit_paid_cents, :integer
    end

    execute("""
    UPDATE groups
    SET policy_version = CASE
      WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
      WHEN booked_on < '2027-01-01' THEN 'flex-14'
      ELSE 'flex-30'
    END,
    refundable_until = CASE
      WHEN rate_plan = 'advance_purchase' THEN NULL
      WHEN booked_on < '2027-01-01' THEN date(arrival_on, '-14 days')
      ELSE date(arrival_on, '-30 days')
    END,
    cash_paid_cents = deposit_paid_cents,
    credit_paid_cents = 0
    """)

    create table(:credit_lots) do
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false
    end

    create index(:credit_lots, [:guest_id, :expires_on, :source_operation_id])

    create table(:credit_allocations) do
      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :delete_all),
          null: false

      add :credit_lot_id,
          references(:credit_lots, on_delete: :delete_all),
          null: false

      add :amount_cents, :integer, null: false
    end

    create unique_index(:credit_allocations, [:group_id, :credit_lot_id])
  end
end
