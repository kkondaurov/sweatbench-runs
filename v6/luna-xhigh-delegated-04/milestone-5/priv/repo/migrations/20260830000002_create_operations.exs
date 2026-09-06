defmodule GroupStay.Repo.Migrations.CreateOperations do
  use Ecto.Migration

  def change do
    create table(:operations) do
      add :operation_id, :string, null: false
      add :operation_type, :string
      add :payload_json, :text, null: false
      add :result_json, :text, null: false
    end

    create unique_index(:operations, [:operation_id])
  end
end
