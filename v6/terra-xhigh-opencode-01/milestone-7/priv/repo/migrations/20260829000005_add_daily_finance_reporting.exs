defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def up do
    create table(:cash_payment_dispositions) do
      add :cash_payment_source_id, references(:cash_payment_sources, on_delete: :restrict),
        null: false

      add :property_id, :string, null: false
      add :disposition, :string, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:cash_payment_dispositions, [:cash_payment_source_id])

    create table(:finance_reporting) do
      add :reporting_key, :integer, null: false, default: 1
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false
    end

    create unique_index(:finance_reporting, [:reporting_key])

    create table(:finance_cash_openings) do
      add :finance_reporting_id, references(:finance_reporting, on_delete: :delete_all),
        null: false

      add :property_id, :string, null: false
      add :opening_held_cents, :integer, null: false
    end

    create unique_index(:finance_cash_openings, [:finance_reporting_id, :property_id])

    create table(:finance_credit_lot_openings) do
      add :finance_reporting_id, references(:finance_reporting, on_delete: :delete_all),
        null: false

      add :hotel_credit_lot_id, references(:hotel_credit_lots, on_delete: :restrict), null: false
      add :opening_available_cents, :integer, null: false
    end

    create unique_index(:finance_credit_lot_openings, [
             :finance_reporting_id,
             :hotel_credit_lot_id
           ])

    create table(:finance_cash_movements) do
      add :posting_on, :date, null: false
      add :property_id, :string, null: false
      add :movement_type, :string, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:finance_cash_movements, [:posting_on, :property_id])

    create table(:finance_credit_movements) do
      add :posting_on, :date, null: false
      add :movement_type, :string, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:finance_credit_movements, [:posting_on])

    create table(:finance_credit_availability_movements) do
      add :posting_on, :date, null: false
      add :hotel_credit_lot_id, references(:hotel_credit_lots, on_delete: :restrict), null: false
      add :amount_cents, :integer, null: false
    end

    create index(:finance_credit_availability_movements, [:hotel_credit_lot_id, :posting_on])

    flush()
    backfill_cash_payment_dispositions()
  end

  def down do
    drop table(:finance_credit_availability_movements)
    drop table(:finance_credit_movements)
    drop table(:finance_cash_movements)
    drop table(:finance_credit_lot_openings)
    drop table(:finance_cash_openings)
    drop table(:finance_reporting)
    drop table(:cash_payment_dispositions)
  end

  defp backfill_cash_payment_dispositions do
    for {column, disposition} <- [
          {:refunded_cents, "refunded"},
          {:retained_cents, "retained"},
          {:converted_to_credit_cents, "converted"}
        ] do
      execute("""
      INSERT INTO cash_payment_dispositions (
        cash_payment_source_id, property_id, disposition, amount_cents
      )
      SELECT sources.id, groups.property_id, '#{disposition}', sources.#{column}
      FROM cash_payment_sources AS sources
      JOIN groups ON groups.id = sources.group_id
      WHERE sources.#{column} > 0
      """)
    end
  end
end
