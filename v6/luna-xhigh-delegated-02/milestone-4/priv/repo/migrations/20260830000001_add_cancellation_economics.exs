defmodule GroupStay.Repo.Migrations.AddCancellationEconomics do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      add :policy_version, :text
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
      add :cash_converted_to_credit_cents, :integer, null: false, default: 0
    end

    execute """
    UPDATE groups
    SET
      policy_version = CASE
        WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
        WHEN booked_on >= '2027-01-01' THEN 'flex-30'
        ELSE 'flex-14'
      END,
      cash_paid_cents = deposit_paid_cents
    WHERE policy_version IS NULL
    """

    create table(:hotel_credit_lots) do
      add :guest_id, :text, null: false
      add :source_operation_id, :text, null: false
      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false
    end

    create index(:hotel_credit_lots, [:guest_id, :expires_on, :source_operation_id])

    create table(:hotel_credit_allocations) do
      add :group_id, :text, null: false
      add :lot_id, references(:hotel_credit_lots, on_delete: :delete_all), null: false
      add :amount_cents, :integer, null: false
    end

    create index(:hotel_credit_allocations, [:group_id])
    create index(:hotel_credit_allocations, [:lot_id])
  end
end
