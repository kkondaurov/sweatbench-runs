defmodule GroupStay.Repo.Migrations.CreateOperations do
  use Ecto.Migration

  # The gateway opens a new operation-identifier namespace with this release, so
  # there is nothing to reconstruct for operations submitted under earlier ones.
  def change do
    create table(:operations) do
      add :operation_id, :string, null: false
      add :type, :string
      add :request_payload, :text, null: false
      add :result, :map, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:operations, [:operation_id])
  end
end
