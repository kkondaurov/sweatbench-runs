defmodule GroupStay.Repo.Migrations.CreatePartnerOperationRecords do
  use Ecto.Migration

  def change do
    create table(:partner_operation_records) do
      add :operation_id, :string, null: false
      add :operation_type, :string
      add :submission, :map, null: false
      add :result, :map, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:partner_operation_records, [:operation_id])
  end
end
