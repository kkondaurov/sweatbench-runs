defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reportings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # At most one inception row can ever exist; the constant column carries a
      # unique index that enforces the singleton under concurrent starts.
      add :singleton_lock, :string, null: false, default: "reporting"
      add :starts_on, :date, null: false
      add :start_operation_id, :string

      add :opening_liability_cents, :integer, null: false, default: 0
      add :opening_applied_credit_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_reportings, [:singleton_lock])

    create table(:finance_opening_cash, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :reporting_id,
          references(:finance_reportings, type: :binary_id, on_delete: :delete_all),
          null: false

      add :property_id, :string, null: false
      add :opening_held_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_opening_cash, [:reporting_id, :property_id])

    create table(:finance_opening_credit_lots, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :reporting_id,
          references(:finance_reportings, type: :binary_id, on_delete: :delete_all),
          null: false

      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all),
        null: false

      add :remaining_cents, :integer, null: false, default: 0
      add :expires_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_opening_credit_lots, [:reporting_id, :credit_lot_id])

    # One finance movement per classification and attribution. Cash movements
    # carry the property where the cash is held or was settled; credit
    # movements are company-wide and name the lot they belong to so unused
    # balances can be tracked to their expiry date.
    create table(:finance_movements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :posting_date, :date, null: false
      add :kind, :string, null: false
      add :property_id, :string
      add :credit_lot_id, :binary_id
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:finance_movements, [:posting_date])
    create index(:finance_movements, [:credit_lot_id])
  end
end
