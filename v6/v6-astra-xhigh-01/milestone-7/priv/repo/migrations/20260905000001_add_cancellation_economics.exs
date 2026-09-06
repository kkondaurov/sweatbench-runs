defmodule GroupStay.Repo.Migrations.AddCancellationEconomics do
  use Ecto.Migration

  def up do
    execute """
    ALTER TABLE groups ADD COLUMN policy_version TEXT NOT NULL DEFAULT 'flex-14'
      CHECK (policy_version IN ('flex-14', 'flex-30', 'advance-nonrefundable'))
    """

    execute """
    UPDATE groups SET policy_version = CASE
      WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
      WHEN booked_on < '2027-01-01' THEN 'flex-14'
      ELSE 'flex-30'
    END
    """

    # Existing deposits are entirely cash. Keep that total and record the credit
    # portion separately so cash is always deposit_paid_cents - credit_paid_cents.
    execute """
    ALTER TABLE groups ADD COLUMN credit_paid_cents INTEGER NOT NULL DEFAULT 0
      CHECK (credit_paid_cents >= 0 AND credit_paid_cents <= deposit_paid_cents)
    """

    execute """
    ALTER TABLE groups ADD COLUMN cash_converted_to_credit_cents INTEGER NOT NULL DEFAULT 0
      CHECK (cash_converted_to_credit_cents >= 0)
    """

    execute """
    CREATE TABLE credit_lots (
      id INTEGER PRIMARY KEY,
      guest_id TEXT NOT NULL,
      source_operation_id TEXT NOT NULL,
      remaining_cents INTEGER NOT NULL CHECK (remaining_cents >= 0),
      expires_on TEXT NOT NULL
    )
    """

    create index(:credit_lots, [:guest_id, :expires_on, :source_operation_id])

    execute """
    CREATE TABLE credit_allocations (
      id INTEGER PRIMARY KEY,
      group_id TEXT NOT NULL REFERENCES groups(group_id) ON DELETE CASCADE,
      credit_lot_id INTEGER NOT NULL REFERENCES credit_lots(id),
      amount_cents INTEGER NOT NULL CHECK (amount_cents > 0)
    )
    """

    create unique_index(:credit_allocations, [:group_id, :credit_lot_id])
  end

  def down do
    drop table(:credit_allocations)
    drop table(:credit_lots)

    execute "ALTER TABLE groups DROP COLUMN cash_converted_to_credit_cents"
    execute "ALTER TABLE groups DROP COLUMN credit_paid_cents"
    execute "ALTER TABLE groups DROP COLUMN policy_version"
  end
end
