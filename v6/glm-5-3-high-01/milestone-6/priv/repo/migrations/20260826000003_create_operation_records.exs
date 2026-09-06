defmodule GroupStay.Repo.Migrations.CreateOperationRecords do
  use Ecto.Migration

  def change do
    create table(:operation_records, primary_key: false) do
      add :id, :serial, primary_key: true
      add :operation_id, :text, null: false
      add :type, :text
      add :payload, :text, null: false
      add :result, :text, null: false

      timestamps()
    end

    create unique_index(:operation_records, [:operation_id])
  end
end
