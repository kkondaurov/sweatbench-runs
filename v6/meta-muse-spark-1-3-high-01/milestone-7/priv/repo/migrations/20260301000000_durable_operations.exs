defmodule GroupStay.Repo.Migrations.DurableOperations do
  use Ecto.Migration

  def change do
    create table(:operation_records) do
      add :operation_id, :string, null: false
      add :operation_type, :string
      add :payload_json, :text, null: false
      add :result_json, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:operation_records, [:operation_id])
  end
end
