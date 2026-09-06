defmodule GroupStay.Repo.Migrations.AddCancellationEconomics do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :policy_version, :string, null: false, default: "flex-14"
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    execute """
    UPDATE groups
    SET policy_version = CASE
      WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
      WHEN rate_plan = 'flexible' AND booked_on < '2027-01-01' THEN 'flex-14'
      WHEN rate_plan = 'flexible' THEN 'flex-30'
      ELSE 'flex-14'
    END,
    cash_paid_cents = deposit_paid_cents,
    credit_paid_cents = 0
    """

    alter table(:ledger_totals) do
      add :cash_converted_to_credit_cents, :integer, null: false, default: 0
      add :credit_liability_cents, :integer, null: false, default: 0
    end

    create table(:hotel_credit_lots) do
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false
    end

    create index(:hotel_credit_lots, [:guest_id, :expires_on, :source_operation_id])

    create table(:hotel_credit_allocations) do
      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :delete_all),
          null: false

      add :lot_id,
          references(:hotel_credit_lots, on_delete: :delete_all),
          null: false

      add :amount_cents, :integer, null: false
    end

    create index(:hotel_credit_allocations, [:group_id])
    create index(:hotel_credit_allocations, [:lot_id])
  end

  def down do
    drop table(:hotel_credit_allocations)
    drop table(:hotel_credit_lots)

    alter table(:ledger_totals) do
      remove :cash_converted_to_credit_cents
      remove :credit_liability_cents
    end

    alter table(:groups) do
      remove :policy_version
      remove :cash_paid_cents
      remove :credit_paid_cents
    end
  end
end
