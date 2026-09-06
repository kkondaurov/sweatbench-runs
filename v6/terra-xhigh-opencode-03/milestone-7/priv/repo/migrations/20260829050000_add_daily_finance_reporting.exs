defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting) do
      add :starts_on, :date, null: false
      add :start_operation_id, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_reporting, [:start_operation_id])

    create table(:finance_entries) do
      add :reporting_id, references(:finance_reporting, on_delete: :delete_all), null: false
      add :partner_operation_id, :string, null: false
      add :entry_index, :integer, null: false
      add :posting_on, :date, null: false
      add :kind, :string, null: false
      add :property_id, :string
      add :credit_lot_id, :binary_id
      add :expires_on, :date
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_entries, [:partner_operation_id, :entry_index])
    create index(:finance_entries, [:reporting_id, :posting_on, :kind, :property_id])
    create index(:finance_entries, [:reporting_id, :credit_lot_id, :posting_on])
  end
end
