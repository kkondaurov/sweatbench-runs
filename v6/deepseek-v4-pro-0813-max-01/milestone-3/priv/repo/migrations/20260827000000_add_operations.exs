defmodule GroupStay.Repo.Migrations.AddOperations do
  use Ecto.Migration

  def change do
    create table(:operations, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :operation_id, :string, null: false
      add :type, :string
      add :payload, :map, null: false
      add :result, :map

      timestamps()
    end

    create unique_index(:operations, [:operation_id])
  end
end
