defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def up do
    create table(:finance_reporting) do
      add :starts_on, :date, null: false
      add :opening_cash_json, :text, null: false
      add :opening_credit_liability_cents, :integer, null: false
    end

    create table(:finance_events) do
      add :operation_id, :text, null: false
      add :posting_on, :date, null: false
      add :property_id, :text
      add :received_cents, :integer, null: false, default: 0
      add :transferred_in_cents, :integer, null: false, default: 0
      add :transferred_out_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
      add :issued_cents, :integer, null: false, default: 0
      add :expired_cents, :integer, null: false, default: 0
      add :consumed_cents, :integer, null: false, default: 0
      add :revoked_cents, :integer, null: false, default: 0
      add :absorbed_cents, :integer, null: false, default: 0
    end

    create index(:finance_events, [:posting_on])
    create index(:finance_events, [:property_id, :posting_on])

    create table(:credit_lot_balance_events) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :operation_id, :text, null: false
      add :occurred_on, :date, null: false
      add :amount_cents, :integer, null: false
      add :event_type, :text, null: false
    end

    create index(:credit_lot_balance_events, [:credit_lot_id, :occurred_on])

    flush()
    backfill_credit_balances()
  end

  def down do
    drop index(:credit_lot_balance_events, [:credit_lot_id, :occurred_on])
    drop table(:credit_lot_balance_events)
    drop index(:finance_events, [:property_id, :posting_on])
    drop index(:finance_events, [:posting_on])
    drop table(:finance_events)
    drop table(:finance_reporting)
  end

  defp backfill_credit_balances do
    repo().query!("""
    INSERT INTO credit_lot_balance_events
      (credit_lot_id, operation_id, occurred_on, amount_cents, event_type)
    SELECT lot.id,
           'legacy-credit-' || lot.id,
           date('now'),
           lot.remaining_cents + COALESCE(SUM(CASE
             WHEN allocation.status = 'held' AND group_record.status = 'active'
             THEN allocation.amount_cents ELSE 0 END), 0),
           'legacy_issued'
    FROM credit_lots AS lot
    LEFT JOIN group_credit_allocations AS allocation
      ON allocation.credit_lot_id = lot.id
    LEFT JOIN groups AS group_record
      ON group_record.id = allocation.group_record_id
    GROUP BY lot.id
    """)

    repo().query!("""
    INSERT INTO credit_lot_balance_events
      (credit_lot_id, operation_id, occurred_on, amount_cents, event_type)
    SELECT lot.id,
           'legacy-applied-' || lot.id,
           date('now'),
           -SUM(allocation.amount_cents),
           'legacy_applied'
    FROM credit_lots AS lot
    JOIN group_credit_allocations AS allocation
      ON allocation.credit_lot_id = lot.id
    JOIN groups AS group_record
      ON group_record.id = allocation.group_record_id
    WHERE allocation.status = 'held' AND group_record.status = 'active'
    GROUP BY lot.id
    """)
  end
end
