defmodule GroupStay.Repo.Migrations.AddDurableOperations do
  use Ecto.Migration

  def change do
    create table(:operations) do
      add :operation_id, :string, null: false
      add :type, :string
      add :payload, :text, null: false
      add :result, :text, null: false

      timestamps()
    end

    create unique_index(:operations, [:operation_id])
  end
end
