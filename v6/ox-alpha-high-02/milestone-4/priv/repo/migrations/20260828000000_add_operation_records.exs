defmodule GroupStay.Repo.Migrations.AddOperationRecords do
  use Ecto.Migration

  def change do
    create table(:operation_records) do
      add :operation_id, :string, null: false
      add :type, :string
      # Canonical JSON of the complete submitted content, insensitive to
      # object key order; array order and values remain significant.
      add :payload, :text, null: false
      # JSON of the exact result returned on the first attempt.
      add :result, :text, null: false

      timestamps()
    end

    create unique_index(:operation_records, [:operation_id])
  end
end
