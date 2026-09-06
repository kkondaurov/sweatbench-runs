defmodule GroupStay.Repo.Migrations.CreateOperationRecords do
  use Ecto.Migration

  def change do
    # The integer primary key doubles as the commit order of the durable
    # records: it increases in the order records were first committed.
    create table(:operation_records) do
      add :operation_id, :string, null: false
      add :type, :string
      add :submission, :map, null: false
      add :result, :map, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:operation_records, [:operation_id])
  end
end
