defmodule GroupStay.Repo.Migrations.AddPolicyVersion do
  use Ecto.Migration

  def up do
    alter table(:group_reservations) do
      add :policy_version, :string, null: false, default: "flex-14"
    end

    execute """
    UPDATE group_reservations
    SET policy_version = CASE
      WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
      WHEN booked_on < '2027-01-01' THEN 'flex-14'
      ELSE 'flex-30'
    END
    """
  end

  def down do
    alter table(:group_reservations) do
      remove :policy_version
    end
  end
end
