defmodule GroupStay.Repo.Migrations.CreatePartnerOperationRecords do
  use Ecto.Migration

  def change do
    create table(:partner_operation_records, primary_key: false) do
      add :commit_order, :integer, primary_key: true
      add :operation_id, :string, null: false
      add :operation_type, :string
      add :submission, :map, null: false
      add :result, :map

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:partner_operation_records, [:operation_id])
  end
end
