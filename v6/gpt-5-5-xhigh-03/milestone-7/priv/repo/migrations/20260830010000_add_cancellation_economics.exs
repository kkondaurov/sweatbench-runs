defmodule GroupStay.Repo.Migrations.AddCancellationEconomics do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      add :policy_version, :string, null: false, default: "flex-14"
      add :credit_paid_cents, :integer, null: false, default: 0
      add :cash_converted_to_credit_cents, :integer, null: false, default: 0
    end

    execute(
      """
      UPDATE groups
      SET policy_version = CASE
        WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
        WHEN rate_plan = 'flexible' AND booked_on >= '2027-01-01' THEN 'flex-30'
        ELSE 'flex-14'
      END
      """,
      ""
    )

    create table(:guest_credit_lots) do
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:guest_credit_lots, [:guest_id, :expires_on, :source_operation_id])

    create table(:group_credit_applications) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :credit_lot_id, references(:guest_credit_lots, on_delete: :restrict), null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:group_credit_applications, [:group_id])
    create index(:group_credit_applications, [:credit_lot_id])
  end
end
