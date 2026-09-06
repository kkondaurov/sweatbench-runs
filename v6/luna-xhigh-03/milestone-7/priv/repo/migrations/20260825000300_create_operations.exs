defmodule GroupStay.Repo.Migrations.CreateOperations do
  use Ecto.Migration

  def change do
    create table(:operations, primary_key: false) do
      add :commit_order, :id, primary_key: true
      add :operation_id, :string, null: false
      add :type, :string
      add :payload_json, :text, null: false
      add :result_json, :text, null: false
    end

    create unique_index(:operations, [:operation_id])
  end
end
