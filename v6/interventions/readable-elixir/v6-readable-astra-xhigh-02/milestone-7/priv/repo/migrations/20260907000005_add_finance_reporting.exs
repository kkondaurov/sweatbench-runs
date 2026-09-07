defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def up do
    # SQLite requires check constraints in the original CREATE TABLE statement.
    execute """
    CREATE TABLE finance_reporting (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      starts_on TEXT NOT NULL
    )
    """

    create table(:finance_entries) do
      add :operation_id, :string, null: false
      add :posted_on, :date, null: false
      add :property_id, :string
      add :classification, :string, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:finance_entries, [:posted_on])
    create index(:finance_entries, [:operation_id])
  end

  def down do
    if repo().query!("SELECT id FROM finance_reporting LIMIT 1").rows != [] do
      raise Ecto.MigrationError,
        message:
          "finance reporting requires a forward migration; downgrade would lose reporting history"
    end

    drop table(:finance_entries)
    execute "DROP TABLE finance_reporting"
  end
end
