defmodule GroupStay.Repo.Migrations.AddDurableOperations do
  use Ecto.Migration

  def change do
    create table(:operation_records) do
      add :operation_id, :string, null: false
      add :type, :string
      add :payload, :text, null: false
      add :result, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:operation_records, [:operation_id])
  end
end
