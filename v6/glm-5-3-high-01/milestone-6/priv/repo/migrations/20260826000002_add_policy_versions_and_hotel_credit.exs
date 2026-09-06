defmodule GroupStay.Repo.Migrations.AddPolicyVersionsAndHotelCredit do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      add :policy_version, :text, null: false, default: "flex-14"
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
    end

    execute(
      """
      UPDATE groups SET
        policy_version = CASE
          WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
          WHEN booked_on >= '2027-01-01' THEN 'flex-30'
          ELSE 'flex-14'
        END,
        cash_paid_cents = deposit_paid_cents
      """,
      "UPDATE groups SET policy_version = 'flex-14', cash_paid_cents = 0, credit_paid_cents = 0, converted_to_credit_cents = 0"
    )

    create table(:credit_lots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :guest_id, :text, null: false
      add :source_operation_id, :text, null: false
      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false

      timestamps()
    end

    create index(:credit_lots, [:guest_id])

    create table(:credit_applications, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false

      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all),
        null: false

      add :amount_cents, :integer, null: false

      timestamps()
    end

    create index(:credit_applications, [:group_id])
    create index(:credit_applications, [:credit_lot_id])
  end
end
