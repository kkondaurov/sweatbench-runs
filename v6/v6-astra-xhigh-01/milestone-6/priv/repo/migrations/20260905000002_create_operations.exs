defmodule GroupStay.Repo.Migrations.CreateOperations do
  use Ecto.Migration

  def change do
    # SQLite's autoincrementing primary key records first-commit order: the
    # immediate transaction permits only one writer until its record commits.
    create table(:operations) do
      add :operation_id, :string, null: false
      add :type, :string
      add :submission, :map, null: false
      add :result, :map, null: false
    end

    create unique_index(:operations, [:operation_id])
  end
end
