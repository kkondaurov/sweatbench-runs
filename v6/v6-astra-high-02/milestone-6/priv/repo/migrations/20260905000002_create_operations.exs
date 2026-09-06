defmodule GroupStay.Repo.Migrations.CreateOperations do
  use Ecto.Migration

  def change do
    # SQLite serializes writers. The generated id therefore orders first commits,
    # including rejected submissions; retries and conflicts never insert a row.
    create table(:operations) do
      add :operation_id, :string, null: false
      add :type, :string
      add :payload, :map, null: false
      add :result, :map, null: false
    end

    create unique_index(:operations, [:operation_id])
  end
end
