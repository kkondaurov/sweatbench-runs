defmodule GroupStay.Repo.Migrations.AddCancellationEconomics do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      # Fixed when a group is opened. Existing rows are backfilled below from their booking date.
      add :policy_version, :string
      # Part of `deposit_paid_cents` funded by hotel credit; the remainder is cash.
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    flush()

    # Groups opened before this release receive the policy their original booking date implies.
    execute("""
    UPDATE groups SET policy_version =
      CASE
        WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
        WHEN booked_on < '2027-01-01' THEN 'flex-14'
        ELSE 'flex-30'
      END
    WHERE policy_version IS NULL
    """)

    create table(:credit_lots) do
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :source_group_ref, references(:groups, on_delete: :restrict), null: false
      add :issued_cents, :integer, null: false
      # Balance not currently applied to a group. It is usable only before `expires_on`.
      add :remaining_cents, :integer, null: false
      add :issued_on, :date, null: false
      # First day the lot is no longer usable.
      add :expires_on, :date, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:credit_lots, [:guest_id, :expires_on, :source_operation_id])

    create table(:credit_applications) do
      add :group_ref, references(:groups, on_delete: :restrict), null: false
      add :lot_ref, references(:credit_lots, on_delete: :restrict), null: false
      add :operation_id, :string, null: false
      add :amount_cents, :integer, null: false
      add :applied_on, :date, null: false
      # `applied` while the group is active, then `restored`, `expired`, or `consumed`.
      add :status, :string, null: false
      add :settled_on, :date

      timestamps(type: :utc_datetime_usec)
    end

    create index(:credit_applications, [:group_ref])
    create index(:credit_applications, [:lot_ref])
    create index(:credit_applications, [:status])
  end

  def down do
    drop table(:credit_applications)
    drop table(:credit_lots)

    alter table(:groups) do
      remove :credit_paid_cents
      remove :policy_version
    end
  end
end
