defmodule GroupStay.Repo.Migrations.AddPolicyVersionAndCreditTables do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      add :policy_version, :text
    end

    execute("""
    UPDATE groups
       SET policy_version = CASE
             WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
             WHEN booked_on >= '2027-01-01' THEN 'flex-30'
             ELSE 'flex-14'
           END
    """)

    # SQLite cannot tighten an added column to NOT NULL in place; the Group
    # changeset enforces the requirement for every application write.

    create table(:credit_lots) do
      add :guest_id, :text, null: false
      add :source_operation_id, :text, null: false
      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false

      timestamps()
    end

    create index(:credit_lots, [:guest_id])

    create table(:credit_fundings) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :amount_cents, :integer, null: false

      timestamps()
    end

    create index(:credit_fundings, [:group_id])
    create index(:credit_fundings, [:credit_lot_id])
  end
end
