defmodule GroupStay.Repo.Migrations.DailyFinanceReport do
  use Ecto.Migration

  def up do
    create table(:finance_reporting, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :starts_on, :date, null: false
      add :opening_liability_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create table(:finance_openings, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :property_id, :text, null: false
      add :opening_held_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_openings, [:property_id])

    create table(:finance_events, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :posted_on, :date, null: false
      add :category, :text, null: false
      add :kind, :text, null: false
      add :property_id, :text
      add :amount_cents, :integer, null: false
      add :operation_id, :text

      # For settlement movements, the payment operation whose cash moved;
      # chargebacks reclassify settled cash through this reference.
      add :related_operation_id, :text

      timestamps(type: :utc_datetime)
    end

    create index(:finance_events, [:posted_on])
    create index(:finance_events, [:property_id])

    alter table(:credit_lots) do
      # The balance a lot carries towards its expiry date; see the schema
      # module. Existing lots take their current remaining balance.
      add :expiry_pending_cents, :integer, null: false, default: 0
    end

    execute("""
    UPDATE credit_lots SET expiry_pending_cents = remaining_cents
    """)
  end

  def down do
    alter table(:credit_lots) do
      remove :expiry_pending_cents
    end

    drop table(:finance_events)
    drop table(:finance_openings)
    drop table(:finance_reporting)
  end
end
