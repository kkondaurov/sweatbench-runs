defmodule GroupStay.Repo.Migrations.AddDurableOperationRecords do
  use Ecto.Migration

  def change do
    create table(:operation_records) do
      add :operation_id, :string, null: false
      add :type, :string, null: false
      add :payload, :text, null: false
      add :result, :text, null: false
    end

    create unique_index(:operation_records, [:operation_id])
  end
end
