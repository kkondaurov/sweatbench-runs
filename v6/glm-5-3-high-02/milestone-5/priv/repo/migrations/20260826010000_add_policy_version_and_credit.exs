defmodule GroupStay.Repo.Migrations.AddPolicyVersionAndCredit do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :policy_version, :string
    end

    # Groups created before this release keep the policy their original
    # booking date implies.
    execute(
      """
      UPDATE groups SET policy_version = CASE
        WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
        WHEN booked_on < '2027-01-01' THEN 'flex-14'
        ELSE 'flex-30'
      END
      """,
      ""
    )

    create table(:credit_lots) do
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false

      timestamps()
    end

    create index(:credit_lots, [:guest_id])
    create index(:credit_lots, [:expires_on])

    create table(:credit_applications) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :amount_cents, :integer, null: false
      add :state, :string, null: false, default: "applied"

      timestamps()
    end

    create index(:credit_applications, [:group_id])
    create index(:credit_applications, [:lot_id])
    create index(:credit_applications, [:state])
  end

  def down do
    drop table(:credit_applications)
    drop table(:credit_lots)

    alter table(:groups) do
      remove :policy_version, :string
    end
  end
end
