defmodule GroupStay.Repo.Migrations.AddCancellationPoliciesAndCredit do
  use Ecto.Migration

  def up do
    alter table(:group_reservations) do
      add :policy_version, :string
      add :credit_paid_cents, :integer, null: false, default: 0
      add :cash_converted_to_credit_cents, :integer, null: false, default: 0
    end

    execute("""
    UPDATE group_reservations
    SET policy_version = CASE
      WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
      WHEN booked_on < '2027-01-01' THEN 'flex-14'
      ELSE 'flex-30'
    END
    """)

    create table(:credit_lots) do
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_lots, [:guest_id, :expires_on, :source_operation_id])

    create table(:credit_applications) do
      add :group_reservation_id,
          references(:group_reservations, on_delete: :delete_all),
          null: false

      add :credit_lot_id, references(:credit_lots, on_delete: :restrict), null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_applications, [:group_reservation_id])
    create index(:credit_applications, [:credit_lot_id])
  end

  def down do
    drop index(:credit_applications, [:credit_lot_id])
    drop index(:credit_applications, [:group_reservation_id])
    drop table(:credit_applications)
    drop index(:credit_lots, [:guest_id, :expires_on, :source_operation_id])
    drop table(:credit_lots)

    alter table(:group_reservations) do
      remove :cash_converted_to_credit_cents
      remove :credit_paid_cents
      remove :policy_version
    end
  end
end
