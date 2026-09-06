defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def up do
    # Request 05 was briefly shipped with this migration version but without its two final
    # tables. Keep databases created during that window upgradeable as well as fresh databases.
    create_if_not_exists table(:payment_transfer_participations) do
      add :payment_funding_id, references(:payment_fundings, on_delete: :restrict), null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create_if_not_exists unique_index(:payment_transfer_participations, [:payment_funding_id])

    create_if_not_exists table(:payment_dispositions) do
      add :payment_funding_id, references(:payment_fundings, on_delete: :restrict), null: false
      add :group_id, references(:groups, on_delete: :restrict), null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      timestamps(type: :utc_datetime)
    end

    create_if_not_exists unique_index(:payment_dispositions, [:payment_funding_id, :group_id])
    create_if_not_exists index(:payment_dispositions, [:group_id])

    execute("""
    INSERT OR IGNORE INTO payment_dispositions
      (payment_funding_id, group_id, refunded_cents, retained_cents,
       converted_to_credit_cents, inserted_at, updated_at)
    SELECT id, group_id, refunded_cents, retained_cents,
           converted_to_credit_cents, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM payment_fundings
    WHERE refunded_cents > 0 OR retained_cents > 0 OR converted_to_credit_cents > 0
    """)

    create table(:finance_reporting_settings) do
      add :singleton, :integer, null: false, default: 1
      add :starts_on, :date, null: false

      add :partner_operation_id, references(:partner_operations, on_delete: :restrict),
        null: false

      add :opening_credit_liability_cents, :integer, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:finance_reporting_settings, [:singleton])
    create unique_index(:finance_reporting_settings, [:partner_operation_id])

    create table(:finance_cash_opening_balances) do
      add :property_id, :string, null: false
      add :opening_held_cents, :integer, null: false
    end

    create unique_index(:finance_cash_opening_balances, [:property_id])

    create table(:finance_credit_opening_lots) do
      add :credit_lot_id, references(:credit_lots, on_delete: :restrict), null: false
      add :expires_on, :date, null: false
      add :available_cents, :integer, null: false
      add :applied_cents, :integer, null: false
    end

    create unique_index(:finance_credit_opening_lots, [:credit_lot_id])

    create table(:finance_cash_movements) do
      add :partner_operation_id, references(:partner_operations, on_delete: :restrict),
        null: false

      add :posting_on, :date, null: false
      add :property_id, :string, null: false
      add :received_cents, :integer, null: false, default: 0
      add :transferred_in_cents, :integer, null: false, default: 0
      add :transferred_out_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
    end

    create unique_index(:finance_cash_movements, [:partner_operation_id, :property_id])
    create index(:finance_cash_movements, [:posting_on, :property_id])

    create table(:finance_credit_movements) do
      add :partner_operation_id, references(:partner_operations, on_delete: :restrict),
        null: false

      add :posting_on, :date, null: false
      add :issued_cents, :integer, null: false, default: 0
      add :expired_cents, :integer, null: false, default: 0
      add :consumed_cents, :integer, null: false, default: 0
      add :revoked_cents, :integer, null: false, default: 0
      add :absorbed_cents, :integer, null: false, default: 0
    end

    create unique_index(:finance_credit_movements, [:partner_operation_id])
    create index(:finance_credit_movements, [:posting_on])

    create table(:finance_credit_lot_events) do
      add :partner_operation_id, references(:partner_operations, on_delete: :restrict),
        null: false

      add :credit_lot_id, references(:credit_lots, on_delete: :restrict), null: false
      add :posting_on, :date, null: false
      add :available_delta_cents, :integer, null: false
      add :applied_delta_cents, :integer, null: false
    end

    create unique_index(:finance_credit_lot_events, [:partner_operation_id, :credit_lot_id])
    create index(:finance_credit_lot_events, [:credit_lot_id, :posting_on])
  end

  def down do
    drop table(:finance_credit_lot_events)
    drop table(:finance_credit_movements)
    drop table(:finance_cash_movements)
    drop table(:finance_credit_opening_lots)
    drop table(:finance_cash_opening_balances)
    drop table(:finance_reporting_settings)
  end
end
