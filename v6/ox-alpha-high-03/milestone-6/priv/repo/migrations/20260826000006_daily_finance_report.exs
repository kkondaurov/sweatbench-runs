defmodule GroupStay.Repo.Migrations.DailyFinanceReport do
  use Ecto.Migration

  def up do
    create table(:finance_reporting_starts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :starts_on, :date, null: false
      add :captured_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create table(:finance_report_openings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :kind, :string, null: false
      add :property_id, :string
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:finance_report_openings, [:kind])

    create table(:finance_report_movements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :posting_date, :date, null: false
      add :property_id, :string
      add :classification, :string, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:finance_report_movements, [:posting_date])
  end

  def down do
    drop table(:finance_report_movements)
    drop table(:finance_report_openings)
    drop table(:finance_reporting_starts)
  end
end
