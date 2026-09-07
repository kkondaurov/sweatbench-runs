defmodule GroupStay.Repo.Migrations.CreatePartnerOperationRecords do
  use Ecto.Migration

  def change do
    create table(:partner_operation_records, primary_key: false) do
      # An INTEGER PRIMARY KEY follows SQLite's durable row insertion order.
      # Records are immutable, so this is also their first-commit order.
      add :commit_order, :integer, primary_key: true
      add :operation_id, :string, null: false
      add :operation_type, :string
      add :submission, :map, null: false
      add :result, :map, null: false

      timestamps(updated_at: false, type: :utc_datetime)
    end

    create unique_index(:partner_operation_records, [:operation_id])
  end
end
