defmodule GroupStay.Repo.Migrations.AddCancellationCreditEconomics do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
      add :cash_converted_to_credit_cents, :integer, null: false, default: 0
      add :policy_version, :string, null: false, default: "flex-30"
    end

    execute("""
    UPDATE groups
    SET cash_paid_cents = deposit_paid_cents,
        policy_version = CASE
          WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
          WHEN booked_on < '2027-01-01' THEN 'flex-14'
          ELSE 'flex-30'
        END
    """)

    create table(:credit_lots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false
      add :revision, :integer, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create index(:credit_lots, [:guest_id, :expires_on, :source_operation_id])

    create table(:credit_allocations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :reservation_id, references(:groups, type: :binary_id, on_delete: :delete_all),
        null: false

      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :restrict),
        null: false

      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_allocations, [:reservation_id])
    create index(:credit_allocations, [:credit_lot_id])
  end

  def down do
    drop table(:credit_allocations)
    drop table(:credit_lots)

    alter table(:groups) do
      remove :policy_version
      remove :cash_converted_to_credit_cents
      remove :credit_paid_cents
      remove :cash_paid_cents
    end
  end
end
