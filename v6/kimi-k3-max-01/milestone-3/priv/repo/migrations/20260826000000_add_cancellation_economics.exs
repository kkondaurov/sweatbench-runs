defmodule GroupStay.Repo.Migrations.AddCancellationEconomics do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      # Existing rows are backfilled below from their rate plan and booking
      # date; the default only satisfies the NOT NULL constraint while the
      # column is added. New groups always set the version explicitly.
      add :policy_version, :string, null: false, default: "flex-14"
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    # Groups created before this release receive the policy their original
    # booking date implies. Every payment so far was cash.
    execute(
      """
      UPDATE groups
      SET policy_version = CASE
            WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
            WHEN booked_on < '2027-01-01' THEN 'flex-14'
            ELSE 'flex-30'
          END,
          cash_paid_cents = deposit_paid_cents
      """,
      "SELECT 1"
    )

    create table(:credit_lots) do
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :expires_on, :date, null: false
      add :remaining_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_lots, [:guest_id])

    create table(:credit_applications) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_applications, [:credit_lot_id])
    create index(:credit_applications, [:group_id])
  end

  def down do
    drop table(:credit_applications)
    drop table(:credit_lots)

    alter table(:groups) do
      remove :policy_version
      remove :cash_paid_cents
      remove :credit_paid_cents
    end
  end
end
