defmodule GroupStay.Repo.Migrations.EvolveCancellationEconomics do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      add :policy_version, :string
      add :cash_paid_cents, :integer, default: 0
      add :credit_paid_cents, :integer, default: 0
    end

    execute "UPDATE groups SET cash_paid_cents = deposit_paid_cents, credit_paid_cents = 0",
            "SELECT 1"

    execute "UPDATE groups SET policy_version = CASE WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable' WHEN booked_on < '2027-01-01' THEN 'flex-14' ELSE 'flex-30' END",
            "SELECT 1"

    create table(:credit_lots) do
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :issued_cents, :integer, null: false, default: 0
      add :remaining_cents, :integer, null: false, default: 0
      add :converted_cash_cents, :integer, null: false, default: 0
      add :expires_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_lots, [:source_operation_id])
    create index(:credit_lots, [:guest_id])

    create table(:credit_usages) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :group_db_id, references(:groups, on_delete: :delete_all), null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_usages, [:group_db_id])
    create index(:credit_usages, [:credit_lot_id])
  end
end
