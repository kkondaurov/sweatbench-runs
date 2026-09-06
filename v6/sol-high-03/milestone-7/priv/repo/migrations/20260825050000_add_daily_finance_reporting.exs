defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting, primary_key: false) do
      add :id, :integer,
        primary_key: true,
        check: %{name: "finance_reporting_singleton", expr: "id = 1"}

      add :starts_on, :date, null: false
    end

    create table(:finance_cash_openings) do
      add :group_id, :string, null: false
      add :property_id, :string, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:finance_cash_openings, [:property_id])

    create table(:finance_credit_openings, primary_key: false) do
      add :credit_lot_id,
          references(:credit_lots, on_delete: :restrict),
          primary_key: true

      add :available_cents, :integer, null: false, default: 0
      add :applied_cents, :integer, null: false, default: 0
      add :expires_on, :date, null: false
    end

    create table(:finance_movements) do
      add :operation_id, :string, null: false
      add :posting_on, :date, null: false
      add :property_id, :string
      add :credit_lot_id, references(:credit_lots, on_delete: :restrict)

      add :kind, :string,
        null: false,
        check: %{
          name: "finance_movements_valid_kind",
          expr:
            "kind IN ('cash_received', 'cash_transferred_in', 'cash_transferred_out', 'cash_refunded', 'cash_retained', 'cash_converted_to_credit', 'cash_reduced', 'cash_charged_back', 'credit_issued', 'credit_expired', 'credit_consumed', 'credit_revoked', 'credit_absorbed')"
        }

      add :amount_cents, :integer, null: false
    end

    create index(:finance_movements, [:posting_on])
    create index(:finance_movements, [:operation_id])
    create index(:finance_movements, [:credit_lot_id])
  end
end
