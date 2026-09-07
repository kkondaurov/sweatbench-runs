defmodule GroupStay.Repo.Migrations.AddCancellationEconomics do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :policy_version, :string, null: false, default: "flex-14"
      add :credit_paid_cents, :integer, null: false, default: 0
      add :cash_converted_to_credit_cents, :integer, null: false, default: 0
    end

    # Use the original booking date, including for already rescheduled or
    # cancelled groups. Their existing cash settlements remain untouched.
    execute """
    UPDATE groups SET policy_version = CASE
      WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
      WHEN booked_on >= '2027-01-01' THEN 'flex-30'
      ELSE 'flex-14'
    END
    """

    create table(:credit_lots) do
      add :source_group_id, references(:groups, column: :group_id, type: :string), null: false
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :issued_cents, :integer, null: false
      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false
    end

    create unique_index(:credit_lots, [:source_group_id])
    create index(:credit_lots, [:guest_id, :expires_on, :source_operation_id])

    create table(:credit_applications) do
      add :group_id, references(:groups, column: :group_id, type: :string), null: false
      add :credit_lot_id, references(:credit_lots), null: false
      add :amount_cents, :integer, null: false
    end

    create unique_index(:credit_applications, [:group_id, :credit_lot_id])
  end

  def down do
    drop table(:credit_applications)
    drop table(:credit_lots)

    alter table(:groups) do
      remove :cash_converted_to_credit_cents
      remove :credit_paid_cents
      remove :policy_version
    end
  end
end
