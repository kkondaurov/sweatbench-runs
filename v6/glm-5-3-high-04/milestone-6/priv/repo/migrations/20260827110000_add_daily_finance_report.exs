defmodule GroupStay.Repo.Migrations.AddDailyFinanceReport do
  use Ecto.Migration

  def up do
    # Signed finance movements recorded when partner operations are applied:
    # per-property cash movements and company-wide credit movements. The
    # autoincrementing id preserves the order in which movements were
    # committed, so the reporting start can exclude the movements that are
    # already part of its opening position.
    create table(:finance_movements, primary_key: false) do
      add :id, :integer, primary_key: true, autoincrement: true
      add :posted_on, :date, null: false
      # "cash" or "credit".
      add :kind, :text, null: false
      # Cash: received, transferred_in, transferred_out, refunded, retained,
      # converted_to_credit, reduced, charged_back.
      # Credit: issued, expired, consumed, revoked, absorbed.
      add :classification, :text, null: false
      # Signed net amount within the classification.
      add :amount_cents, :integer, null: false
      add :property_id, :text
      add :operation_id, :text
      add :payment_operation_id, :text
      add :credit_lot_id, :binary_id

      timestamps(type: :utc_datetime)
    end

    create index(:finance_movements, [:posted_on])
    create index(:finance_movements, [:payment_operation_id])
    create index(:finance_movements, [:credit_lot_id])

    # The single durable reporting inception point: reporting starts once,
    # with the opening hotel-credit liability and the movement floor
    # (movements committed before the start operation are part of the
    # opening position).
    create table(:finance_reporting, primary_key: false) do
      add :id, :integer, primary_key: true
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false
      add :movement_floor_id, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    # The opening cash position per property, snapshotted when reporting
    # starts: cash held by the active groups of that property at that moment.
    create table(:finance_cash_openings, primary_key: false) do
      add :id, :integer, primary_key: true, autoincrement: true
      add :property_id, :text, null: false
      add :opening_held_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_cash_openings, [:property_id])
  end

  def down do
    drop unique_index(:finance_cash_openings, [:property_id])

    drop table(:finance_cash_openings)
    drop table(:finance_reporting)

    drop index(:finance_movements, [:credit_lot_id])
    drop index(:finance_movements, [:payment_operation_id])
    drop index(:finance_movements, [:posted_on])

    drop table(:finance_movements)
  end
end
