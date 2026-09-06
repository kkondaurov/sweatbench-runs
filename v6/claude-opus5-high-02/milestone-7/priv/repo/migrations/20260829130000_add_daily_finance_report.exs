defmodule GroupStay.Repo.Migrations.AddDailyFinanceReport do
  use Ecto.Migration

  def change do
    # Reporting has one inception point for the whole service: the first applied start operation
    # writes the only row this table ever holds.
    create table(:finance_reporting_starts) do
      add :starts_on, :date, null: false
      add :operation_id, :string, null: false

      timestamps(type: :utc_datetime)
    end

    # Every finance effect of an operation processed after that inception, stamped with the date
    # the effect posts to. Reports are aggregations of these rows, so they are only ever inserted
    # and a report never has to be recomputed and stored.
    create table(:finance_movements) do
      add :posting_date, :date, null: false
      add :scope, :string, null: false
      add :kind, :string, null: false
      add :property_id, :string
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all)
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:finance_movements, [:scope, :posting_date])
    create index(:finance_movements, [:credit_lot_id])
  end
end
