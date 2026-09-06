defmodule GroupStay.Repo.Migrations.EvolveCancellationEconomics do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :policy_version, :string
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
      add :cash_converted_to_credit_cents, :integer, null: false, default: 0
    end

    execute("""
    UPDATE groups
    SET
      cash_paid_cents = deposit_paid_cents,
      credit_paid_cents = 0,
      cash_converted_to_credit_cents = 0,
      policy_version = CASE
        WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
        WHEN booked_on < '2027-01-01' THEN 'flex-14'
        ELSE 'flex-30'
      END
    """)

    create table(:hotel_credit_lots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :original_cents, :integer, null: false
      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:hotel_credit_lots, [:guest_id, :expires_on, :source_operation_id])

    create table(:applied_hotel_credits, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_pk_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false

      add :hotel_credit_lot_id,
          references(:hotel_credit_lots, type: :binary_id, on_delete: :restrict),
          null: false

      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:applied_hotel_credits, [:group_pk_id])
    create index(:applied_hotel_credits, [:hotel_credit_lot_id])
  end

  def down do
    drop table(:applied_hotel_credits)
    drop table(:hotel_credit_lots)

    alter table(:groups) do
      remove :cash_converted_to_credit_cents
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :policy_version
    end
  end
end
