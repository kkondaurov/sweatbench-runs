defmodule GroupStay.Repo.Migrations.CreateOperationRecords do
  use Ecto.Migration

  def change do
    create table(:operation_records) do
      add :operation_id, :string, null: false
      add :operation_type, :string
      add :payload_json, :text, null: false
      add :result_json, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:operation_records, [:operation_id])
  end
end
