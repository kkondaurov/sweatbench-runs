defmodule GroupStay.Repo.Migrations.CreateOperationRecords do
  use Ecto.Migration

  def change do
    # Operations submitted by earlier releases are not reconstructed: the gateway starts a new
    # operation-identifier namespace with this release.
    create table(:operation_records, primary_key: false) do
      # AUTOINCREMENT never reuses a value, so `id` is the order in which records were committed.
      add :id, :bigserial, primary_key: true
      add :operation_id, :string, null: false
      # The submitted `type` when it is a string; the complete submission is in `payload`.
      add :type, :string
      # The complete submitted operation as canonical JSON (object keys sorted).
      add :payload, :text, null: false
      # The result returned for the operation, as JSON.
      add :result, :text, null: false
      add :status, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:operation_records, [:operation_id])
  end
end
