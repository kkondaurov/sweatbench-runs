defmodule GroupStay.Repo.Migrations.CreateOperationRecords do
  use Ecto.Migration

  def change do
    create table(:operation_records) do
      add :operation_id, :text, null: false
      add :operation_type, :text
      add :payload_json, :text, null: false
      add :result_json, :text, null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create unique_index(:operation_records, [:operation_id])
  end
end
