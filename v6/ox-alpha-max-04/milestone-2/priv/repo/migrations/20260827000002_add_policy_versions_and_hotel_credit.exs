defmodule GroupStay.Repo.Migrations.AddPolicyVersionsAndHotelCredit do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      add :policy_version, :string, null: false, default: "flex-14"
    end

    # Groups created before this release receive the policy that their
    # original booking date implies.
    execute(
      """
      UPDATE groups
      SET policy_version = CASE
        WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
        WHEN booked_on >= '2027-01-01' THEN 'flex-30'
        ELSE 'flex-14'
      END
      """,
      ""
    )

    create table(:credit_lots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_lots, [:guest_id])

    create table(:group_credit_applications, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all), null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:group_credit_applications, [:group_id])
    create index(:group_credit_applications, [:lot_id])
  end
end
