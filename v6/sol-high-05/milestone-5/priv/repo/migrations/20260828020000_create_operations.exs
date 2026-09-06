defmodule GroupStay.Repo.Migrations.CreateOperations do
  use Ecto.Migration

  def change do
    create table(:operations, primary_key: false) do
      add :commit_order, :integer, primary_key: true, autogenerate: true
      add :operation_id, :string, null: false
      add :operation_type, :string
      add :submitted_content, :map, null: false
      add :result, :map, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:operations, [:operation_id])
  end
end
