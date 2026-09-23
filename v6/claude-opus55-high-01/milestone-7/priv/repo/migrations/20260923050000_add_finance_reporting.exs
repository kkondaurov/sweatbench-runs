defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    # At most one row: the start operation that enabled daily finance reporting.
    create table(:finance_reporting) do
      add :starts_on, :date, null: false
      add :operation_id, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # Finance effects on report dates. Opening positions are recorded when reporting starts;
    # every later applied operation records its movements on its posting date.
    create table(:finance_postings) do
      add :operation_id, :string, null: false
      add :posting_date, :date, null: false
      # Set for held cash; `nil` for the company-wide credit liability and lot balances.
      add :property_id, :string
      # Set for lot balances, which expire with their lot.
      add :lot_ref, references(:credit_lots, on_delete: :restrict)
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:finance_postings, [:posting_date])
    create index(:finance_postings, [:lot_ref])
  end
end
