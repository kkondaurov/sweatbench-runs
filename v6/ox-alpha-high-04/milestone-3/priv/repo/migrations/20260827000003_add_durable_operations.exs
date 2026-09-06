defmodule GroupStay.Repo.Migrations.AddDurableOperations do
  use Ecto.Migration

  def change do
    # Durable idempotency and audit records for operations first received by
    # this release. No reconstruction of earlier releases' submissions is
    # needed: the gateway starts a new operation-identifier namespace here.
    #
    # The generated `id` also preserves the order in which durable records
    # were first committed.
    create table(:operations) do
      add :operation_id, :string, null: false
      add :type, :string
      add :payload_json, :text, null: false
      add :result_json, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:operations, [:operation_id])
  end
end
