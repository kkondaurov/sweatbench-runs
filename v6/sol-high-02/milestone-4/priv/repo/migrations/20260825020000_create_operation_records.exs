defmodule GroupStay.Repo.Migrations.CreateOperationRecords do
  use Ecto.Migration

  def change do
    create table(:operation_records) do
      add :operation_id, :text, null: false
      add :operation_type, :text
      add :submission, :map, null: false
      add :result, :map, null: false
    end

    create unique_index(:operation_records, [:operation_id])
  end
end
