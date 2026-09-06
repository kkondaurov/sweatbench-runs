defmodule GroupStay.Repo.Migrations.CreatePartnerOperations do
  use Ecto.Migration

  def change do
    create table(:partner_operations) do
      add :operation_id, :string, null: false
      add :operation_type, :string
      add :payload, :map, null: false
      add :result, :map

      timestamps(type: :utc_datetime)
    end

    create unique_index(:partner_operations, [:operation_id])
    create index(:partner_operations, [:inserted_at, :id])
  end
end
