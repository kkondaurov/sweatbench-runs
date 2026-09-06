defmodule GroupStay.Repo.Migrations.CreateOperationRecords do
  use Ecto.Migration

  def change do
    # The integer primary key doubles as the commit-order sequence: SQLite
    # serializes writes, so rowid order matches the order in which durable
    # records were first committed.
    create table(:operation_records) do
      add :operation_id, :string, null: false
      add :type, :string
      add :submission, :text, null: false
      add :result, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:operation_records, [:operation_id])
  end
end
