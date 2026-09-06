defmodule GroupStay.Repo.Migrations.CreatePartnerOperations do
  use Ecto.Migration

  def change do
    create table(:partner_operations) do
      add :operation_id, :string, null: false
      add :operation_type, :string
      add :submitted_payload, :map, null: false
      add :result, :map, null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create unique_index(:partner_operations, [:operation_id])
  end
end
