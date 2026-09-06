defmodule GroupStay.Repo.Migrations.CreateDurableOperations do
  use Ecto.Migration

  def change do
    # `id` is an incrementing integer so the table itself preserves the
    # order in which durable records were first committed.
    create table(:durable_operations) do
      add :operation_id, :string, null: false
      add :op_type, :string
      add :payload_json, :text, null: false
      add :result_json, :text, null: false

      timestamps()
    end

    create unique_index(:durable_operations, [:operation_id])
  end
end
