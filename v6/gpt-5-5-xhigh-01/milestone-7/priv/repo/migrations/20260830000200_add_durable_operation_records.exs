defmodule GroupStay.Repo.Migrations.AddDurableOperationRecords do
  use Ecto.Migration

  def change do
    create table(:operation_records) do
      add :operation_id, :string, null: false
      add :operation_type, :string
      add :payload_json, :text, null: false
      add :result_json, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:operation_records, [:operation_id])
    create index(:operation_records, [:inserted_at, :id])
  end
end
