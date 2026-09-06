defmodule GroupStay.Repo.Migrations.CreateOperationRecords do
  use Ecto.Migration

  def change do
    create table(:operation_records) do
      # The partner-supplied identifier; the primary key preserves the order in
      # which durable records were first committed.
      add :operation_id, :string, null: false
      add :type, :string
      # The complete submitted content and the remembered result, as JSON.
      add :payload, :text, null: false
      add :result, :text, null: false
      add :status, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:operation_records, [:operation_id])
  end
end
