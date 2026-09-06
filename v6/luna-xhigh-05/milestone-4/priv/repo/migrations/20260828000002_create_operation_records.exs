defmodule GroupStay.Repo.Migrations.CreateOperationRecords do
  use Ecto.Migration

  def change do
    create table(:operation_records) do
      add :operation_id, :string, null: false
      add :operation_type, :string
      add :payload_json, :text, null: false
      add :result_json, :text, null: false
    end

    create unique_index(:operation_records, [:operation_id])
  end
end
