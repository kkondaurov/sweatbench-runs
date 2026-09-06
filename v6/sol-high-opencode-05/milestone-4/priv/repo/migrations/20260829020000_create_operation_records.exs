defmodule GroupStay.Repo.Migrations.CreateOperationRecords do
  use Ecto.Migration

  def change do
    create table(:operation_records, primary_key: false) do
      add :commit_order, :bigserial, primary_key: true
      add :operation_id, :string, null: false
      add :operation_type, :string
      add :submission, :map, null: false
      add :result, :map, null: false
    end

    create unique_index(:operation_records, [:operation_id])
  end
end
