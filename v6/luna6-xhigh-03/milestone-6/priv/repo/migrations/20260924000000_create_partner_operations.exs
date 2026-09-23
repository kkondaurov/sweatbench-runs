defmodule GroupStay.Repo.Migrations.CreatePartnerOperations do
  use Ecto.Migration

  def change do
    create table(:partner_operations) do
      add :operation_id, :text, null: false
      add :operation_type, :text
      add :submitted_content, :map, null: false
      add :result, :map, null: false
    end

    create unique_index(:partner_operations, [:operation_id])
  end
end
