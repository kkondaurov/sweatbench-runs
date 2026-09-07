defmodule GroupStay.Repo.Migrations.CreatePartnerOperations do
  use Ecto.Migration

  def change do
    create table(:partner_operations) do
      add :operation_id, :string, null: false
      add :type, :string
      add :submission, :map, null: false
      add :result, :map, null: false
    end

    create unique_index(:partner_operations, [:operation_id])
  end
end
