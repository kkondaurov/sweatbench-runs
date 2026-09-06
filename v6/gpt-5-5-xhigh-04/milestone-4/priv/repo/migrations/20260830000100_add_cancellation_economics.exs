defmodule GroupStay.Repo.Migrations.AddCancellationEconomics do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      add :policy_version, :string, null: false, default: "flex-14"
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
      add :cash_converted_to_credit_cents, :integer, null: false, default: 0
    end

    execute(
      """
      UPDATE groups
      SET
        cash_paid_cents = deposit_paid_cents,
        credit_paid_cents = 0,
        cash_converted_to_credit_cents = 0,
        policy_version = CASE
          WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
          WHEN booked_on >= '2027-01-01' THEN 'flex-30'
          ELSE 'flex-14'
        END
      """,
      """
      UPDATE groups
      SET
        cash_paid_cents = 0,
        credit_paid_cents = 0,
        cash_converted_to_credit_cents = 0,
        policy_version = 'flex-14'
      """
    )

    create table(:hotel_credit_lots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:hotel_credit_lots, [:guest_id, :expires_on, :source_operation_id])

    create table(:group_credit_applications, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :reservation_id, references(:groups, type: :binary_id, on_delete: :delete_all),
        null: false

      add :credit_lot_id, references(:hotel_credit_lots, type: :binary_id, on_delete: :restrict),
        null: false

      add :amount_cents, :integer, null: false
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create index(:group_credit_applications, [:reservation_id])
    create index(:group_credit_applications, [:credit_lot_id])
    create index(:group_credit_applications, [:active])
  end
end
