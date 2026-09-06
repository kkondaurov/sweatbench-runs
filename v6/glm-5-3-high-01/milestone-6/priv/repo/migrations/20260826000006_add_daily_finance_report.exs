defmodule GroupStay.Repo.Migrations.AddDailyFinanceReport do
  use Ecto.Migration

  def up do
    # The durable reporting inception point. The `singleton` column with its
    # unique index keeps exactly one row, so a concurrent second start loses.
    create table(:finance_reporting_states, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :singleton, :integer, null: false, default: 1
      add :starts_on, :date, null: false
      add :started_by_operation_id, :string, null: false
      add :opening_credit_liability_cents, :integer, null: false

      timestamps()
    end

    create unique_index(:finance_reporting_states, [:singleton])

    # Held cash per property when reporting started; the opening position of
    # the report for `starts_on`.
    create table(:finance_property_openings, primary_key: false) do
      add :property_id, :string, primary_key: true
      add :opening_held_cents, :integer, null: false

      timestamps()
    end

    # One row per finance effect of an applied operation, on its posting date.
    # Cash movements carry a property; credit movements are company-wide.
    create table(:finance_movements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :operation_id, :string
      add :posting_date, :date, null: false
      add :property_id, :string
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false

      timestamps()
    end

    create index(:finance_movements, [:posting_date])

    # Signed changes to a credit lot's remaining balance with posting dates,
    # so unused credit can be expired on the date after `expires_on` even
    # when no operation is submitted that day. Lots already funded when
    # reporting started carry one baseline event dated the day before
    # `starts_on`.
    create table(:finance_credit_lot_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :credit_lot_id, :binary_id, null: false
      add :posting_date, :date, null: false
      add :delta_cents, :integer, null: false

      timestamps()
    end

    create index(:finance_credit_lot_events, [:credit_lot_id])

    # Where a payment's settled cash was dispositioned, so a later chargeback
    # can report its reversal at the property where the cash was settled.
    create table(:payment_settlements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :payment_operation_id, :string, null: false
      add :group_id, :binary_id, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_cents, :integer, null: false, default: 0

      timestamps()
    end

    create index(:payment_settlements, [:payment_operation_id])
  end

  def down do
    drop table(:payment_settlements)
    drop table(:finance_credit_lot_events)
    drop table(:finance_movements)
    drop table(:finance_property_openings)
    drop table(:finance_reporting_states)
  end
end
