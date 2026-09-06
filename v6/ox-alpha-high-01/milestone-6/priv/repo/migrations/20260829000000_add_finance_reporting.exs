defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def up do
    # One row per finance effect of an operation processed after reporting
    # started, in the display orientation of its report movement: a positive
    # amount means the classification grew by that amount, so a normal refund
    # stores a positive `refunded` amount while the held-cash balance falls.
    create table(:finance_movements, primary_key: false) do
      add :id, :integer, primary_key: true
      add :posted_on, :date, null: false
      add :domain, :string, null: false
      add :classification, :string, null: false
      add :property_id, :string
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:finance_movements, [:posted_on])
    create index(:finance_movements, [:payment_operation_id])

    # The durable reporting inception point. The financial state immediately
    # before the first applied start operation is snapshotted here and becomes
    # every report's opening position.
    create table(:reporting_starts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :starts_on, :date, null: false
      add :opening_cash_cents, :map, null: false
      add :opening_credit_liability_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end
  end

  def down do
    drop table(:reporting_starts)
    drop table(:finance_movements)
  end
end
