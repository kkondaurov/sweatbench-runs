defmodule GroupStay.Repo.Migrations.CreateOperations do
  use Ecto.Migration

  def change do
    # Durable idempotency and audit records for partner operations. The
    # autoincrementing primary key preserves the order in which records were
    # first committed.
    create table(:operations, primary_key: false) do
      add :id, :integer, primary_key: true, autoincrement: true
      add :operation_id, :text, null: false
      add :type, :text
      # Canonical JSON of the complete submitted operation.
      add :payload, :text, null: false
      # JSON of the result returned for the first submission.
      add :result, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:operations, [:operation_id])
  end
end
