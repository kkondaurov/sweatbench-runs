defmodule GroupStay.Repo.Migrations.AddCancellationEconomics do
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
    SET cash_paid_cents = deposit_paid_cents,
        credit_paid_cents = 0,
        cash_converted_to_credit_cents = 0,
        policy_version = CASE
          WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
          WHEN booked_on < '2027-01-01' THEN 'flex-14'
          ELSE 'flex-30'
        END
    """)

    create table(:hotel_credit_lots) do
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false
    end

    create index(:hotel_credit_lots, [:guest_id, :expires_on, :source_operation_id])

    create table(:hotel_credit_applications) do
      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :delete_all),
          null: false

      add :credit_lot_id,
          references(:hotel_credit_lots, column: :id, on_delete: :delete_all),
          null: false

      add :amount_cents, :integer, null: false
    end

    create index(:hotel_credit_applications, [:group_id])
    create index(:hotel_credit_applications, [:credit_lot_id])
  end

  def down do
    drop table(:hotel_credit_applications)
    drop table(:hotel_credit_lots)

    alter table(:groups) do
      remove :cash_converted_to_credit_cents
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :policy_version
    end
  end
end
