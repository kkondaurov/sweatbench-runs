defmodule GroupStay.Repo.Migrations.CreatePartnerOperations do
  use Ecto.Migration

  def change do
    create table(:partner_operations, primary_key: false) do
      add :commit_order, :integer, primary_key: true, autogenerate: true
      add :operation_id, :string, null: false
      add :operation_type, :string
      add :submission, :map, null: false
      add :result, :map, null: false
    end

    create unique_index(:partner_operations, [:operation_id])
  end
end
