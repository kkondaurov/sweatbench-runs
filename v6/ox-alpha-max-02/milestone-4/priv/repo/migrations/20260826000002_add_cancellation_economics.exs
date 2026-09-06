defmodule GroupStay.Repo.Migrations.AddCancellationEconomics do
  use Ecto.Migration

  def change do
    alter table(:groups, primary_key: false) do
      add :policy_version, :string, null: false, default: "flex-14"
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
      add :cash_converted_to_credit_cents, :integer, null: false, default: 0
    end

    # Before hotel credit existed, every cent applied to a deposit was cash, so
    # upgraded groups keep reporting their held cash correctly.
    execute("UPDATE groups SET cash_paid_cents = deposit_paid_cents")

    execute("""
    UPDATE groups
       SET policy_version = CASE
             WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
             WHEN booked_on >= '2027-01-01' THEN 'flex-30'
             ELSE 'flex-14'
           END
    """)

    create table(:credit_lots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :issued_on, :date, null: false
      add :expires_on, :date, null: false
      add :remaining_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:credit_lots, [:guest_id])

    create table(:group_credit_applications, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false

      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all),
        null: false

      add :applied_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:group_credit_applications, [:group_id, :credit_lot_id])
    create index(:group_credit_applications, [:credit_lot_id])
  end
end
