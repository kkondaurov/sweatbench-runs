defmodule GroupStay.Repo.Migrations.CreateOperations do
  use Ecto.Migration

  def change do
    create table(:operations) do
      add :operation_id, :string, null: false
      add :type, :string
      add :payload, :map, null: false
      add :result, :map

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create unique_index(:operations, [:operation_id])
  end
end
