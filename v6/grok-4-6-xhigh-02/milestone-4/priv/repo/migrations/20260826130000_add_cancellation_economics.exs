defmodule GroupStay.Repo.Migrations.AddCancellationEconomics do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      add :policy_version, :string
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
      add :cash_converted_to_credit_cents, :integer, null: false, default: 0
    end

    create table(:credit_lots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_lots, [:guest_id])
    create unique_index(:credit_lots, [:guest_id, :source_operation_id])

    create table(:credit_applications, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :amount_cents, :integer, null: false

      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false

      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :restrict),
        null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:credit_applications, [:group_id, :credit_lot_id])
    create index(:credit_applications, [:group_id])
    create index(:credit_applications, [:credit_lot_id])

    execute(
      """
      UPDATE groups
      SET policy_version = CASE
            WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
            WHEN booked_on >= '2027-01-01' THEN 'flex-30'
            ELSE 'flex-14'
          END,
          cash_paid_cents = deposit_paid_cents
      """,
      """
      UPDATE groups
      SET policy_version = NULL,
          cash_paid_cents = 0
      """
    )
  end
end
