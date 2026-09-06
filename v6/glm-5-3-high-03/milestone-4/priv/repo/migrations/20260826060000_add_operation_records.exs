defmodule GroupStay.Repo.Migrations.AddOperationRecords do
  use Ecto.Migration

  def change do
    # The integer primary key is a SQLite rowid alias: it is assigned in
    # insertion order and therefore preserves the order in which durable
    # operation records were first committed.
    create table(:operation_records, primary_key: false) do
      add :id, :integer, primary_key: true
      add :operation_id, :string, null: false
      add :type, :string
      add :payload, :map, null: false
      add :result, :map, null: false

      timestamps(type: :utc_datetime)
    end

    # Guarantees at-most-once effects for concurrent retries of the same
    # operation identifier.
    create unique_index(:operation_records, [:operation_id])
  end
end
