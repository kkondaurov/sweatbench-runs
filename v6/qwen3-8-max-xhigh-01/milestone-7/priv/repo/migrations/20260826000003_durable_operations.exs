defmodule GroupStay.Repo.Migrations.DurableOperations do
  use Ecto.Migration

  def change do
    # The auto-incrementing primary key preserves the order in which durable
    # records were first committed, which the service keeps as its audit
    # record of what the gateway submitted.
    create table(:operation_records) do
      add :operation_id, :string, null: false
      add :type, :string
      add :payload, :map, null: false
      add :result, :map, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:operation_records, [:operation_id])
  end
end
