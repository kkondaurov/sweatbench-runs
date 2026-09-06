defmodule GroupStay.Repo.Migrations.AddCancellationEconomics do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :policy_version, :string
      add :refundable_until, :date
      add :cash_paid_cents, :integer
      add :credit_paid_cents, :integer
    end

    execute """
    UPDATE groups
    SET policy_version = CASE
      WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
      WHEN booked_on < '2027-01-01' THEN 'flex-14'
      ELSE 'flex-30'
    END
    WHERE policy_version IS NULL
    """

    execute """
    UPDATE groups
    SET refundable_until = CASE
      WHEN policy_version = 'flex-14' THEN date(arrival_on, '-14 days')
      WHEN policy_version = 'flex-30' THEN date(arrival_on, '-30 days')
      ELSE NULL
    END
    WHERE refundable_until IS NULL
    """

    execute """
    UPDATE groups
    SET cash_paid_cents = deposit_paid_cents,
        credit_paid_cents = 0
    WHERE cash_paid_cents IS NULL OR credit_paid_cents IS NULL
    """

    alter table(:ledger) do
      add :cash_converted_to_credit_cents, :integer, null: false, default: 0
    end

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
          references(:credit_lots, column: :id, on_delete: :delete_all),
          null: false

      add :amount_cents, :integer, null: false
    end

    create index(:credit_allocations, [:group_id])
    create index(:credit_allocations, [:credit_lot_id])
  end

  def down do
    drop table(:credit_allocations)
    drop table(:credit_lots)

    alter table(:ledger) do
      remove :cash_converted_to_credit_cents
    end

    alter table(:groups) do
      remove :refundable_until
      remove :policy_version
      remove :cash_paid_cents
      remove :credit_paid_cents
    end
  end
end
