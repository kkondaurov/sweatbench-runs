defmodule GroupStay.Repo.Migrations.AddPartnerOperationRecords do
  use Ecto.Migration

  def change do
    create table(:partner_operations) do
      add :operation_id, :string, null: false
      add :operation_type, :string, null: false
      add :submission_json, :text, null: false
      add :result_json, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:partner_operations, [:operation_id])
  end
end
