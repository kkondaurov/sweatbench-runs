defmodule GroupStay.Repo.Migrations.CreatePartnerOperations do
  use Ecto.Migration

  def change do
    create table(:partner_operations) do
      add :operation_id, :text, null: false
      add :operation_type, :text
      add :payload_json, :text, null: false
      add :result_json, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:partner_operations, [:operation_id])
  end
end
