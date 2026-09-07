defmodule GroupStay.Repo.Migrations.CreateOperations do
  use Ecto.Migration

  def change do
    create table(:operations) do
      add :operation_id, :string, null: false
      add :operation_type, :string
      add :submission, :map, null: false
      add :result, :map, null: false
    end

    create unique_index(:operations, [:operation_id])
  end
end
