defmodule GroupStay.Repo.Migrations.CreateOperations do
  use Ecto.Migration

  def change do
    create table(:operations) do
      add :operation_id, :text, null: false
      add :operation_type, :text
      add :commit_sequence, :integer, null: false
      add :payload_json, :text, null: false
      add :result_json, :text, null: false
    end

    create unique_index(:operations, [:operation_id])
    create unique_index(:operations, [:commit_sequence])
  end
end
