defmodule GroupStay.Repo.Migrations.DurableOperations do
  use Ecto.Migration

  def up do
    create table(:operation_records) do
      add :operation_id, :string, null: false
      add :type, :string
      add :payload, :text, null: false
      add :result, :text, null: false

      timestamps()
    end

    create unique_index(:operation_records, [:operation_id])
  end

  def down do
    drop table(:operation_records)
  end
end
