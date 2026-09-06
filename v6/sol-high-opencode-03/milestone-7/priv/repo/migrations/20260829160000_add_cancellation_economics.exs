defmodule GroupStay.Repo.Migrations.AddCancellationEconomics do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      add :policy_version, :text, null: false, default: "flex-14"
      add :credit_paid_cents, :integer, null: false, default: 0
      add :cash_converted_to_credit_cents, :integer, null: false, default: 0
    end

    execute(
      "UPDATE groups SET policy_version = 'advance-nonrefundable' WHERE rate_plan = 'advance_purchase'",
      "UPDATE groups SET policy_version = 'flex-14' WHERE rate_plan = 'advance_purchase'"
    )

    execute(
      "UPDATE groups SET policy_version = 'flex-30' WHERE rate_plan = 'flexible' AND booked_on >= '2027-01-01'",
      "UPDATE groups SET policy_version = 'flex-14' WHERE policy_version = 'flex-30'"
    )

    create table(:credit_lots) do
      add :guest_id, :text, null: false
      add :source_operation_id, :text, null: false
      add :issued_on, :date, null: false
      add :expires_on, :date, null: false
      add :remaining_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_lots, [:guest_id, :expires_on, :source_operation_id])

    create table(:credit_allocations) do
      add :group_id, references(:groups, column: :group_id, type: :text, on_delete: :delete_all),
        null: false

      add :credit_lot_id, references(:credit_lots, on_delete: :restrict), null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_allocations, [:group_id])
    create index(:credit_allocations, [:credit_lot_id])
  end
end
