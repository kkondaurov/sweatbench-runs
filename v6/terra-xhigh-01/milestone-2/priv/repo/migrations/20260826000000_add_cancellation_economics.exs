defmodule GroupStay.Repo.Migrations.AddCancellationEconomics do
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
      WHEN rate_plan = 'flexible' AND booked_on < '2027-01-01' THEN 'flex-14'
      WHEN rate_plan = 'flexible' THEN 'flex-30'
      ELSE 'advance-nonrefundable'
    END
    """)

    create table(:hotel_credit_lots) do
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:hotel_credit_lots, [:guest_id, :expires_on, :source_operation_id])

    create table(:group_credit_payments) do
      add :group_reservation_id, references(:group_reservations, on_delete: :delete_all),
        null: false

      add :hotel_credit_lot_id, references(:hotel_credit_lots, on_delete: :restrict), null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:group_credit_payments, [:group_reservation_id])
    create index(:group_credit_payments, [:hotel_credit_lot_id])
  end

  def down do
    drop table(:group_credit_payments)
    drop table(:hotel_credit_lots)

    alter table(:group_reservations) do
      remove :cash_converted_to_credit_cents
      remove :credit_paid_cents
      remove :policy_version
    end
  end
end
