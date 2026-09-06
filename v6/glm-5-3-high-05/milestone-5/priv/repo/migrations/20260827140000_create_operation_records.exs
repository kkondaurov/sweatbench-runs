defmodule GroupStay.Repo.Migrations.CreateOperationRecords do
  use Ecto.Migration

  def change do
    # The integer autoincrement primary key preserves the order in which
    # durable records were first committed, which makes the table usable as
    # an audit trail of what the gateway submitted.
    create table(:operation_records, primary_key: false) do
      add :id, :id, primary_key: true
      add :operation_key, :text, null: false
      add :type, :text
      add :payload, :text, null: false
      add :status, :text, null: false
      add :result, :text, null: false

      timestamps()
    end

    create unique_index(:operation_records, [:operation_key])
  end
end
