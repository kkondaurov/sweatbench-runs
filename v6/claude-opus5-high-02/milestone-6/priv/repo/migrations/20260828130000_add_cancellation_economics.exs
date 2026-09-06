defmodule GroupStay.Repo.Migrations.AddCancellationEconomics do
  use Ecto.Migration

  def change do
    # Deposits can now be funded by cash or by hotel credit, so the paid total splits in two.
    rename table(:groups), :deposit_paid_cents, to: :cash_paid_cents

    alter table(:groups) do
      add :credit_paid_cents, :integer, null: false, default: 0
      add :cash_converted_to_credit_cents, :integer, null: false, default: 0
      add :policy_version, :string
    end

    # Groups opened before this release keep the policy their original booking date implies.
    execute(
      """
      UPDATE groups SET policy_version = CASE
        WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
        WHEN booked_on >= '2027-01-01' THEN 'flex-30'
        ELSE 'flex-14'
      END
      """,
      "SELECT 1"
    )

    create table(:credit_lots) do
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :issued_on, :date, null: false
      add :expires_on, :date, null: false
      add :original_cents, :integer, null: false
      add :remaining_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_lots, [:guest_id])
    create index(:credit_lots, [:expires_on])

    create table(:credit_applications) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :amount_cents, :integer, null: false
      add :applied_on, :date, null: false
      add :status, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_applications, [:group_id])
    create index(:credit_applications, [:status])
  end
end
