defmodule GroupStay.Repo.Migrations.CreateOperationRecords do
  use Ecto.Migration

  def change do
    create table(:operations) do
      add :operation_id, :string, null: false
      add :type, :string
      add :payload, :map, null: false
      add :result, :map
    end

    create unique_index(:operations, [:operation_id])
  end
end
