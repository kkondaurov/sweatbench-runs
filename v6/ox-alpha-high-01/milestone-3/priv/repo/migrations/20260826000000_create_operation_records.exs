defmodule GroupStay.Repo.Migrations.CreateOperationRecords do
  use Ecto.Migration

  def change do
    # The integer primary key is SQLite's rowid alias, so rows are numbered in
    # the order their idempotency records were first committed.
    create table(:operation_records, primary_key: false) do
      add :id, :integer, primary_key: true
      add :operation_id, :string, null: false
      add :type, :string
      add :submission, :map, null: false
      add :result, :map, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:operation_records, [:operation_id])
  end
end
