defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  @moduledoc """
  The durable reporting inception point and the raw finance movements behind
  the daily report.

  Starting finance reporting captures the opening position — cash held per
  property and each credit lot's available balance — exactly once. Every
  later applied operation appends signed movement rows at its reporting
  posting date; a day's report aggregates those rows on top of the opening
  position, so reading reports never changes state and later submissions
  naturally revise earlier open days.
  """

  def change do
    create table(:finance_reporting_settings) do
      # Only one inception row may ever exist.
      add :singleton, :integer, null: false, default: 1
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false, default: 0

      timestamps()
    end

    create unique_index(:finance_reporting_settings, [:singleton])

    create table(:finance_property_openings) do
      add :property_id, :text
      add :cash_held_cents, :integer, null: false, default: 0

      timestamps()
    end

    create index(:finance_property_openings, [:property_id])

    create table(:finance_lot_openings) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :available_cents, :integer, null: false, default: 0

      timestamps()
    end

    create unique_index(:finance_lot_openings, [:credit_lot_id])

    create table(:finance_cash_movements) do
      add :posting_date, :date, null: false
      add :property_id, :text
      add :kind, :text, null: false
      add :amount_cents, :integer, null: false

      timestamps()
    end

    create index(:finance_cash_movements, [:posting_date])
    create index(:finance_cash_movements, [:property_id])

    create table(:finance_credit_movements) do
      add :posting_date, :date, null: false
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :kind, :text, null: false
      add :amount_cents, :integer, null: false

      timestamps()
    end

    create index(:finance_credit_movements, [:posting_date])
    create index(:finance_credit_movements, [:credit_lot_id])
  end
end
