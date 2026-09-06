defmodule GroupStay.Repo.Migrations.AddCancellationEconomics do
  use Ecto.Migration

  def up do
    alter table(:group_reservations) do
      add :policy_version, :text
      add :credit_paid_cents, :integer, null: false, default: 0
      add :cash_converted_to_credit_cents, :integer, null: false, default: 0
    end

    execute("""
    UPDATE group_reservations
    SET policy_version =
      CASE
        WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
        WHEN booked_on < '2027-01-01' THEN 'flex-14'
        ELSE 'flex-30'
      END
    WHERE policy_version IS NULL
    """)

    create table(:hotel_credit_lots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :guest_id, :text, null: false
      add :source_operation_id, :text, null: false
      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:hotel_credit_lots, [:guest_id])
    create index(:hotel_credit_lots, [:expires_on])
    create index(:hotel_credit_lots, [:guest_id, :expires_on, :source_operation_id])

    create table(:hotel_credit_applications, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :group_reservation_id,
          references(:group_reservations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :hotel_credit_lot_id,
          references(:hotel_credit_lots, type: :binary_id, on_delete: :restrict),
          null: false

      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:hotel_credit_applications, [:group_reservation_id])
    create index(:hotel_credit_applications, [:hotel_credit_lot_id])
  end

  def down do
    drop table(:hotel_credit_applications)
    drop table(:hotel_credit_lots)

    alter table(:group_reservations) do
      remove :cash_converted_to_credit_cents
      remove :credit_paid_cents
      remove :policy_version
    end
  end
end
