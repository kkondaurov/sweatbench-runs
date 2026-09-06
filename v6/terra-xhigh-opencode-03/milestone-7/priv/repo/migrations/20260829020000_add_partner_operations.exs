defmodule GroupStay.Repo.Migrations.AddPartnerOperations do
  use Ecto.Migration

  def change do
    create table(:partner_operations) do
      add :operation_id, :string, null: false
      add :operation_type, :string
      add :payload, :map, null: false
      add :result, :map, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:partner_operations, [:operation_id])
  end
end
