defmodule GroupStay.Repo.Migrations.AddDurablePartnerOperations do
  use Ecto.Migration

  def change do
    create table(:partner_operations) do
      add :operation_id, :string, null: false
      add :operation_type, :string
      add :submitted_payload, :text, null: false
      add :result, :text, null: false

      timestamps(updated_at: false)
    end

    create unique_index(:partner_operations, [:operation_id])
  end
end
