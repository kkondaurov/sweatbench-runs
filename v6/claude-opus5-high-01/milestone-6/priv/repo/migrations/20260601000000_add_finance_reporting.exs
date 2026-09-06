defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  @moduledoc """
  Gives finance a reporting inception point and a movement log behind it.

  Current balances alone cannot say how a day moved, so every finance effect of
  an applied operation is written down against the date it posts to. The position
  carried into the reporting window is written the same way, dated the day before
  reporting starts, so a report is always the movements before a date plus the
  movements on it.

  Databases from earlier releases have not started reporting, so there is nothing
  to backfill: the opening position is captured from live state when the first
  `start_finance_reporting` operation is applied.
  """

  use Ecto.Migration

  def change do
    create table(:finance_reporting) do
      add :singleton, :integer, null: false, default: 0
      add :starts_on, :date, null: false
      add :operation_id, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:finance_reporting, [:singleton])

    create table(:finance_cash_movements) do
      add :posting_date, :date, null: false
      add :property_id, :string, null: false
      add :classification, :string, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:finance_cash_movements, [:posting_date])

    create table(:finance_credit_movements) do
      add :posting_date, :date, null: false
      add :lot_ref, references(:credit_lots, on_delete: :delete_all), null: false
      add :event, :string, null: false
      add :amount_cents, :integer, null: false, default: 0
      add :remaining_delta_cents, :integer, null: false, default: 0
      add :applied_delta_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:finance_credit_movements, [:posting_date])
    create index(:finance_credit_movements, [:lot_ref])
  end
end
