defmodule GroupStay.Repo.Migrations.CancellationEconomics do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :policy_version, :string
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
      add :cash_converted_to_credit_cents, :integer, null: false, default: 0
    end

    execute """
    UPDATE groups SET policy_version = 'advance-nonrefundable'
    WHERE rate_plan = 'advance_purchase'
    """

    execute """
    UPDATE groups SET policy_version = CASE
      WHEN booked_on < '2027-01-01' THEN 'flex-14'
      ELSE 'flex-30'
    END
    WHERE rate_plan = 'flexible'
    """

    execute """
    UPDATE groups SET cash_paid_cents = deposit_paid_cents
    """

    create table(:credit_lots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :expires_on, :date, null: false
      add :remaining_cents, :integer, null: false, default: 0

      timestamps()
    end

    create index(:credit_lots, [:guest_id])

    create table(:credit_applications, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :amount_cents, :integer, null: false

      add :lot_id,
          references(:credit_lots, column: :id, type: :binary_id, on_delete: :delete_all),
          null: false

      add :group_id, references(:groups, column: :id, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps()
    end

    create index(:credit_applications, [:lot_id])
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
