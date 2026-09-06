defmodule GroupStay.Repo.Migrations.CreateOperationRecords do
  use Ecto.Migration

  def change do
    # The integer primary key is the SQLite ROWID; insertion order therefore
    # preserves the order in which durable records were first committed.
    create table(:operation_records, primary_key: false) do
      add :id, :integer, primary_key: true
      add :operation_id, :string, null: false
      add :type, :string
      add :status, :string, null: false
      add :request, :text, null: false
      add :result, :text, null: false

      timestamps()
    end

    create unique_index(:operation_records, [:operation_id])
  end
end
