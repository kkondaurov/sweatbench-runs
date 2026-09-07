defmodule GroupStay.Repo.Migrations.CreatePartnerOperations do
  use Ecto.Migration

  def change do
    create table(:partner_operations, primary_key: false) do
      # SQLite assigns integer primary keys in insertion order. Because partner
      # operations use serialized write transactions, this is also durable
      # first-commit order.
      add :commit_order, :integer, primary_key: true
      add :operation_id, :string, null: false
      add :operation_type, :string
      add :submitted_payload, :map, null: false
      add :result, :map, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:partner_operations, [:operation_id])
  end
end
