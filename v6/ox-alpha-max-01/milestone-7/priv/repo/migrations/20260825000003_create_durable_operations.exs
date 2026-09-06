defmodule GroupStay.Repo.Migrations.CreateDurableOperations do
  use Ecto.Migration

  def change do
    # One row per operation identifier the gateway first submitted to this
    # release. The auto-incrementing primary key preserves the order in
    # which records were first committed, making the table an audit trail.
    create table(:durable_operations) do
      add :operation_id, :text, null: false
      add :type, :text
      add :submitted_json, :text, null: false
      add :result_json, :text, null: false

      timestamps()
    end

    create unique_index(:durable_operations, [:operation_id])
  end
end
