defmodule GroupStay.Repo.Migrations.AddDurableOperations do
  use Ecto.Migration

  def change do
    create table(:operation_records) do
      add :operation_id, :string, null: false
      # Null when the submitted operation carried no usable type; the full
      # submission is always in `payload`.
      add :type, :string
      add :payload, :text, null: false
      add :result, :text, null: false

      timestamps(type: :utc_datetime)
    end

    # At-most-once under concurrent retries: the losing transaction fails to
    # insert and rolls back its domain changes.
    create unique_index(:operation_records, [:operation_id])
  end
end
