defmodule GroupStay.Repo.Migrations.AddCreditAndPolicyVersions do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :policy_version, :text, null: false, default: "flex-14"
      add :credit_paid_cents, :integer, null: false, default: 0
      add :cash_converted_cents, :integer, null: false, default: 0
    end

    # Groups opened before this release keep the policy implied by their
    # original booking date.
    execute """
    UPDATE groups
    SET policy_version = CASE
      WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
      WHEN booked_on >= '2027-01-01' THEN 'flex-30'
      ELSE 'flex-14'
    END
    """

    create table(:credit_lots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :guest_id, :text, null: false
      add :source_operation_id, :text, null: false
      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_lots, [:guest_id])

    create table(:credit_applications, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :credit_lot_id, references(:credit_lots, type: :binary_id), null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_applications, [:group_id])
  end

  def down do
    drop table(:credit_applications)
    drop table(:credit_lots)

    alter table(:groups) do
      remove :cash_converted_cents
      remove :credit_paid_cents
      remove :policy_version
    end
  end
end
