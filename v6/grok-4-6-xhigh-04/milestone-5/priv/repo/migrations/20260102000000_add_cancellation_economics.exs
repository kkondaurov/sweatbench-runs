defmodule GroupStay.Repo.Migrations.AddCancellationEconomics do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :policy_version, :string
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
      add :cash_converted_to_credit_cents, :integer, null: false, default: 0
    end

    execute """
    UPDATE groups SET
      cash_paid_cents = deposit_paid_cents,
      policy_version = CASE
        WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
        WHEN booked_on >= '2027-01-01' THEN 'flex-30'
        ELSE 'flex-14'
      END
    """

    create table(:credit_lots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false
    end

    create index(:credit_lots, [:guest_id])
    create unique_index(:credit_lots, [:guest_id, :source_operation_id])

    create table(:credit_applications, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :expires_on, :date, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:credit_applications, [:group_id])
  end

  def down do
    drop table(:credit_applications)
    drop table(:credit_lots)

    alter table(:groups) do
      remove :policy_version
      remove :cash_paid_cents
      remove :credit_paid_cents
      remove :cash_converted_to_credit_cents
    end
  end
end
