defmodule GroupStay.Repo.Migrations.AddCancellationEconomics do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :policy_version, :string
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
      add :cash_converted_to_credit_cents, :integer, null: false, default: 0
    end

    flush()

    # Groups opened before this release keep the policy their booking date implies.
    # Dates are stored as ISO 8601 text, so they compare as strings.
    execute """
    UPDATE groups
       SET policy_version =
             CASE
               WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
               WHEN booked_on >= '2027-01-01' THEN 'flex-30'
               ELSE 'flex-14'
             END
    """

    # Every deposit payment recorded before this release was cash.
    execute "UPDATE groups SET cash_paid_cents = deposit_paid_cents"

    create table(:credit_lots) do
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :issued_cents, :integer, null: false
      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:credit_lots, [:guest_id, :expires_on, :source_operation_id])

    create table(:credit_redemptions) do
      add :lot_ref, references(:credit_lots, on_delete: :delete_all), null: false
      add :group_ref, references(:groups, on_delete: :delete_all), null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:credit_redemptions, [:lot_ref])
    create index(:credit_redemptions, [:group_ref])
  end

  def down do
    drop table(:credit_redemptions)
    drop table(:credit_lots)

    alter table(:groups) do
      remove :cash_converted_to_credit_cents
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :policy_version
    end
  end
end
