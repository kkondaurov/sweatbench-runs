defmodule GroupStay.Repo.Migrations.CreateOperations do
  use Ecto.Migration

  def change do
    # SQLite serializes writers. This generated ID therefore records first-commit
    # order, independently of partner identifiers and operation dates.
    create table(:operations) do
      add :operation_id, :string, null: false
      add :submission, :map, null: false
      add :result, :map, null: false
    end

    create unique_index(:operations, [:operation_id])
  end
end
