defmodule GroupStay.Repo.Migrations.AddCancellationEconomics do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :policy_version, :string
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
      add :converted_cents, :integer, null: false, default: 0
    end

    # Groups created before this release receive the policy their original
    # booking date implies; historic paid deposit counts as cash.
    execute """
    UPDATE groups SET
      policy_version = CASE
        WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
        WHEN booked_on < '2027-01-01' THEN 'flex-14'
        ELSE 'flex-30'
      END,
      cash_paid_cents = deposit_paid_cents
    """

    create table(:credit_lots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :available_cents, :integer, null: false
      add :expires_on, :date, null: false

      timestamps()
    end

    create index(:credit_lots, [:guest_id])

    create table(:credit_applications, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all),
        null: false

      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false

      add :amount_cents, :integer, null: false

      timestamps()
    end

    create index(:credit_applications, [:group_id])
    create index(:credit_applications, [:lot_id])
  end

  def down do
    drop(index(:credit_applications, [:lot_id]))
    drop(index(:credit_applications, [:group_id]))
    drop(table(:credit_applications))
    drop(index(:credit_lots, [:guest_id]))
    drop(table(:credit_lots))

    alter table(:groups) do
      remove :policy_version
      remove :cash_paid_cents
      remove :credit_paid_cents
      remove :converted_cents
    end
  end
end
