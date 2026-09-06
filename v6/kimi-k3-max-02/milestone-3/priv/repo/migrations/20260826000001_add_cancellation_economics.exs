defmodule GroupStay.Repo.Migrations.AddCancellationEconomics do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      # Fixed when the group is opened. Existing rows are backfilled below from
      # the policy their original booking date implies.
      add :policy_version, :string, null: false, default: "flex-14"
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
      add :cash_converted_cents, :integer, null: false, default: 0
    end

    # Groups recorded before this release only ever received cash, so their
    # paid deposit was entirely cash. Rollback drops the columns, so the down
    # direction needs no statement.
    execute(
      """
      UPDATE groups SET policy_version = CASE
        WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
        WHEN booked_on < '2027-01-01' THEN 'flex-14'
        ELSE 'flex-30'
      END
      """,
      "SELECT 1"
    )

    execute(
      "UPDATE groups SET cash_paid_cents = deposit_paid_cents",
      "SELECT 1"
    )

    create table(:credit_lots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :guest_id, :string, null: false
      add :source_operation_id, :string
      add :original_cents, :integer, null: false
      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_lots, [:guest_id])

    create table(:credit_applications, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all),
        null: false

      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false

      add :amount_cents, :integer, null: false
      add :status, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_applications, [:group_id])
    create index(:credit_applications, [:credit_lot_id])
  end
end
