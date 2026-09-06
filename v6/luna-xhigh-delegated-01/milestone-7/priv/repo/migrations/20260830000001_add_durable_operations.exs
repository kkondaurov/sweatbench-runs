defmodule GroupStay.Repo.Migrations.AddDurableOperations do
  use Ecto.Migration

  def change do
    create table(:operations) do
      add :operation_id, :string, null: false
      add :type, :string
      add :payload_json, :text, null: false
      add :result_json, :text, null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create unique_index(:operations, [:operation_id])
  end
end
