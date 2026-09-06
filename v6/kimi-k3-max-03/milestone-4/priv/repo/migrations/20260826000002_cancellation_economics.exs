defmodule GroupStay.Repo.Migrations.CancellationEconomics do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      add :policy_version, :string
      add :refundable_until, :date
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
      add :cash_converted_to_credit_cents, :integer, null: false, default: 0
    end

    # Groups created by earlier releases receive the policy their booking date
    # implies; any cash they recorded counts as cash-paid.
    execute(
      """
      UPDATE groups SET
        policy_version = CASE
          WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
          WHEN booked_on < '2027-01-01' THEN 'flex-14'
          ELSE 'flex-30'
        END,
        refundable_until = CASE
          WHEN rate_plan = 'advance_purchase' THEN NULL
          WHEN booked_on < '2027-01-01' THEN date(arrival_on, '-14 days')
          ELSE date(arrival_on, '-30 days')
        END,
        cash_paid_cents = deposit_paid_cents
      """,
      ""
    )

    create table(:credit_lots) do
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :expires_on, :date, null: false
      add :remaining_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:credit_lots, [:guest_id])

    create table(:credit_applications) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_applications, [:group_id])
    create index(:credit_applications, [:credit_lot_id])
  end
end
