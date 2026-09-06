defmodule GroupStay.Repo.Migrations.CancellationEconomics do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      add :policy_version, :string, null: false, default: "flex-14"
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
    end

    # Groups created before this release keep the policy their original
    # booking date implies, and all deposit paid so far was cash.
    execute """
            UPDATE groups SET policy_version = 'advance-nonrefundable'
            WHERE rate_plan = 'advance_purchase'
            """,
            "SELECT 1"

    execute """
            UPDATE groups SET policy_version = 'flex-30'
            WHERE rate_plan != 'advance_purchase' AND booked_on >= '2027-01-01'
            """,
            "SELECT 1"

    execute "UPDATE groups SET cash_paid_cents = deposit_paid_cents", "SELECT 1"

    create table(:credit_lots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :guest_id, :string, null: false
      add :source_operation_id, :string
      add :issued_cents, :integer, null: false
      add :remaining_cents, :integer, null: false
      add :issued_on, :date, null: false
      add :expires_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_lots, [:guest_id, :expires_on])

    create table(:credit_applications, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :lot_id, references(:credit_lots, type: :binary_id), null: false
      add :amount_cents, :integer, null: false
      add :occurred_on, :date, null: false
      add :state, :string, null: false, default: "applied"

      timestamps(type: :utc_datetime)
    end

    create index(:credit_applications, [:group_id])
    create index(:credit_applications, [:lot_id])
  end
end
