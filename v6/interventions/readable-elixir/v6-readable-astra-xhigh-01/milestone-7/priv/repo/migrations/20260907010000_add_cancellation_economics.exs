defmodule GroupStay.Repo.Migrations.AddCancellationEconomics do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      # SQLite requires a default when adding a non-null column to a populated table.
      # Backfill from the original booking date before the migration commits.
      add :policy_version, :string, null: false, default: "flex-14"
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    execute """
    UPDATE groups
    SET policy_version = CASE
      WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
      WHEN booked_on < '2027-01-01' THEN 'flex-14'
      ELSE 'flex-30'
    END,
    cash_paid_cents = deposit_paid_cents
    """

    create table(:credit_lots) do
      add :guest_id, :string, null: false
      add :source_group_id, references(:groups, column: :group_id, type: :string), null: false
      add :source_operation_id, :string, null: false
      add :issued_cents, :integer, null: false
      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:credit_lots, [:source_group_id])
    create index(:credit_lots, [:guest_id, :expires_on, :source_operation_id])

    create table(:credit_allocations) do
      add :group_id, references(:groups, column: :group_id, type: :string), null: false
      add :credit_lot_id, references(:credit_lots), null: false
      add :operation_id, :string, null: false
      add :amount_cents, :integer, null: false
      add :status, :string, null: false, default: "applied"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:credit_allocations, [:group_id, :status])
    create index(:credit_allocations, [:credit_lot_id])
  end

  def down do
    drop table(:credit_allocations)
    drop table(:credit_lots)

    alter table(:groups) do
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :policy_version
    end
  end
end
