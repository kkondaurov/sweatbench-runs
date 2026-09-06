defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    # Reporting starts once. The single row remembers the partner operation
    # that started it, the reporting start date, and the company-wide hotel
    # credit liability immediately before that operation was processed.
    create table(:finance_reporting_state) do
      add :singleton, :string, null: false, default: "current"
      add :operation_id, :string, null: false
      add :starts_on, :date, null: false
      add :opening_liability_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_reporting_state, [:singleton])

    # Per-property opening held cash snapshotted when reporting starts. Only
    # nonzero balances are stored.
    create table(:finance_opening_cash) do
      add :property_id, :string, null: false
      add :opening_held_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:finance_opening_cash, [:property_id])

    # One row per finance movement recorded by an applied partner operation
    # processed after reporting started. Cash rows carry a property and signed
    # amounts (a chargeback reverses an earlier refund with a negative refund
    # row). Credit rows carry a lot and positive magnitudes in their named
    # classification. `revoked_dormant` rows are entitlements revoked from a
    # lot after its expiry passed: they never appear in a report but let the
    # report reconstruct the frozen expiry at each lot's boundary.
    create table(:finance_movements) do
      add :posting_date, :date, null: false
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
      add :operation_id, :string
      add :property_id, :string
      add :credit_lot_id, references(:credit_lots, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:finance_movements, [:posting_date])
    create index(:finance_movements, [:property_id])
    create index(:finance_movements, [:credit_lot_id])
  end
end
